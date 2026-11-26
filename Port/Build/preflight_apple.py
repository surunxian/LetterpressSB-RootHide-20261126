#!/usr/bin/env python3
"""Capture Apple arm64e codegen and reject bare witness descriptor arguments.
This checks one known failure boundary, not the complete Swift ABI or device safety.
"""
import argparse, hashlib, json, pathlib, platform, re, subprocess, sys
TOKEN=r'(?:%[-A-Za-z0-9_.$]+|@"[^"]+"|@[-A-Za-z0-9_.$]+)'


def arguments(text):
    out=[]; start=0; depth=0; quoted=False; escape=False
    for i,c in enumerate(text):
        if c=='"' and not escape: quoted=not quoted
        if not quoted:
            if c in '([{<': depth+=1
            elif c in ')]}>': depth-=1
            elif c==',' and depth==0: out.append(text[start:i].strip());start=i+1
        escape=c=='\\' and not escape
    out.append(text[start:].strip());return out


def inspect_ir(text):
    globals={m.group(1):m.group(2) for m in re.finditer(r'^('+TOKEN+r')\s*=\s*(.+)$',text,re.M) if m.group(1).startswith('@')}
    findings=[]
    for function in re.findall(r'^define\b.*?^}',text,re.M|re.S):
        definitions={m.group(1):m.group(2) for m in re.finditer(r'^\s*('+TOKEN+r')\s*=\s*(.+)$',function,re.M)}
        def trace(value,seen=()):
            if len(seen)>16:return False,'trace depth exceeded'
            if '@llvm.ptrauth.sign' in value:
                match=re.search(r'@llvm\.ptrauth\.sign\w*\((.*)\)',value)
                args=arguments(match.group(1)) if match else []
                if len(args)>=3 and re.fullmatch(r'i32\s+2',args[1]):
                    return True,'descriptor argument derives from ptrauth.sign using data key 2'
                return False,'unknown/wrong ptrauth sign key'
            if 'ptrauth (' in value and re.search(r'i32\s+2\b',value):
                return True,'descriptor uses native authenticated pointer constant with data key 2'
            tokens=re.findall(TOKEN,value)
            # Only casts and loads may be traversed. Arbitrary calls/phi cannot prove provenance.
            if value.lstrip().startswith(('inttoptr ','ptrtoint ','bitcast ','addrspacecast ','load ')) or len(tokens)==1:
                for token in tokens:
                    if token in seen:continue
                    if token.startswith('%') and token in definitions:
                        ok,why=trace(definitions[token],seen+(token,))
                        if ok:return ok,why
                    if token in globals:
                        global_value=globals[token]
                        if 'section "llvm.ptrauth"' in global_value and re.search(r'i32\s+2\b',global_value):
                            return True,'descriptor derives from llvm.ptrauth constant with data key 2'
            return False,'bare or unrecognised descriptor provenance; manual review required'
        for line in function.splitlines():
            match=re.search(r'\bcall\b.*?@swift_getWitnessTable\((.*)\)',line)
            if not match:continue
            args=arguments(match.group(1));first=args[0] if args else ''
            ok,why=trace(first)
            findings.append({'argument':first,'signing_observed':ok,'reason':why,'call':line.strip()})
    return {'calls':findings,'call_count':len(findings),'all_descriptors_signed':bool(findings) and all(x['signing_observed'] for x in findings),'limit':'Only witness descriptor signing provenance is checked; not complete ABI/device validation.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',required=True,type=pathlib.Path);parser.add_argument('--inspect-ir',type=pathlib.Path);args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    if args.inspect_ir:
        report=inspect_ir(args.inspect_ir.read_text());(args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));return 0 if report['all_descriptors_signed'] else 2
    if platform.system()!='Darwin':raise SystemExit('Requires real Apple Xcode on macOS; no Linux fallback')
    def run(cmd):
        result=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
        records.append({'command':cmd,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
        (args.output/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
        if result.returncode:raise RuntimeError('Apple probe compilation failed; see commands.json')
        return result.stdout.strip()
    records=[]
    swift=run(['/usr/bin/xcrun','--find','swiftc']);sdk=run(['/usr/bin/xcrun','--sdk','iphoneos','--show-sdk-path'])
    compiler=run([swift,'--version'])
    if 'Apple Swift version' not in compiler:raise SystemExit('Selected compiler does not identify as Apple Swift')
    probes={'CompactMap':'public func compact(_ xs: [String?]) -> [String] { xs.compactMap { $0 } }\n','Conditional':'public protocol P {}\npublic protocol Q {}\npublic struct G<T> {}\nextension G: P where T: Q {}\npublic func use<T: P>(_ t: T.Type) {}\npublic func run<T: Q>(_ t: T.Type) { use(G<T>.self) }\n'}
    reports={}
    for name,source in probes.items():
        file=args.output/(name+'.swift');file.write_text(source)
        common=[swift,'-frontend','-parse-as-library','-module-name','LP'+name,'-target','arm64e-apple-ios16.0','-sdk',sdk,'-Onone']
        if name=='Conditional':common+=['-parse-stdlib']
        for flag,suffix in [('-emit-ir','.ll'),('-emit-assembly','.s'),('-emit-object','.o')]:run(common+[flag,str(file),'-o',str(args.output/(name+suffix))])
        reports[name]=inspect_ir((args.output/(name+'.ll')).read_text())
    passed=all(x['all_descriptors_signed'] for x in reports.values())
    report={'status':'SIGNING_OBSERVED' if passed else 'MANUAL_REVIEW_REQUIRED','compiler':compiler,'sdk':sdk,'probes':reports,'device_tested':False,'complete_abi_verified':False}
    (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));return 0 if passed else 2

if __name__=='__main__':sys.exit(main())
