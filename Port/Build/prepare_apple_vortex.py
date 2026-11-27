#!/usr/bin/env python3
"""Adapt only a verified Vortex checkout's package/resources for a SpringBoard dylib."""
import argparse,hashlib,json,pathlib,plistlib,shutil,subprocess
from adapt_vortex_timeline_isolation import isolate_timeline
REV='26e036c4f04efcc019c95d43bfeffeaefbef3c99'
PNG={'circle':'66f338f38c5fd786c72ed0906cf3a5bb29b170f1e5f02b8a92a964409a7929e1','confetti':'d1b3ae95ae78a0b7e65dd860a75e75436f623334a52b8c9641c31b223a9bdf72','sparkle':'b6e23edd5647fd3557826c30f8bc569f0c235766cfb785d58e899eb3bc3c1817'}
ADAPTER='''// LetterpressSB packaging adapter. The upstream renderer is unchanged.
import Foundation
import Darwin
extension Bundle {
    static let module: Bundle = {
        var image = Dl_info()
        if dladdr(#dsohandle, &image) != 0, let filename = image.dli_fname {
            let directory = URL(fileURLWithPath: String(cString: filename)).deletingLastPathComponent()
            if let bundle = Bundle(url: directory.appendingPathComponent("Vortex_Vortex.bundle")) { return bundle }
        }
        // Avoid an SPM fatalError in SpringBoard when installation is incomplete.
        return Bundle.main
    }()
}
'''
def require(ok,msg):
 if not ok:raise SystemExit(msg)
def digest(f):return hashlib.sha256(f.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source-packages',type=pathlib.Path);p.add_argument('--local-package',required=True,type=pathlib.Path);p.add_argument('--project-spec',type=pathlib.Path);p.add_argument('--products',type=pathlib.Path);p.add_argument('--stage-only',action='store_true');a=p.parse_args()
local=a.local_package.resolve()
if not a.stage_only:
 require(a.source_packages is not None and a.project_spec is not None,'Missing dependency checkout or project spec')
 matches=[]
 for checkout in (a.source_packages/'checkouts').iterdir():
  if not (checkout/'Package.swift').is_file():continue
  r=subprocess.run(['git','-C',str(checkout),'rev-parse','HEAD'],capture_output=True,text=True)
  if r.returncode==0 and r.stdout.strip()==REV:matches.append(checkout)
 require(len(matches)==1,'Exactly one pinned Vortex checkout is required')
 source=matches[0]
 require(not local.exists(),'Refusing to overwrite an existing local package')
 local.mkdir(parents=True)
 for name in ('Package.swift','LICENSE','Sources','Tests'):
  f=source/name
  require(f.exists() and not f.is_symlink(),'Missing/linked pinned package input: '+name)
  if f.is_dir():
   require(not any(x.is_symlink() for x in f.rglob('*')),'Symlinks in dependency source are forbidden')
   shutil.copytree(f,local/name)
  else:shutil.copy2(f,local/name)
 # SwiftPM checkouts are intentionally read-only. Only make our isolated copy writable.
 for copied in local.rglob('*'):
  if copied.is_dir():copied.chmod(copied.stat().st_mode | 0o700)
  elif copied.is_file():copied.chmod(copied.stat().st_mode | 0o600)
 manifest=local/'Package.swift';original=manifest.read_text()
 old='.target(\n            name: "Vortex"),'
 require(original.count(old)==1,'Unrecognised Vortex package manifest; no broad patch permitted')
 manifest.write_text(original.replace(old,'.target(\n            name: "Vortex",\n            exclude: ["Resources/Assets.xcassets"]),'))
 (local/'Sources/Vortex/LPSBResourceBundle.swift').write_text(ADAPTER)
 spec=a.project_spec;original_spec=spec.read_text()
 oldspec='    url: https://github.com/twostraws/Vortex.git\n    revision: '+REV
 require(original_spec.count(oldspec)==1,'Unexpected Vortex package pin in project spec')
 spec.write_text(original_spec.replace(oldspec,'    path: '+json.dumps(str(local))))
 # Audit only: verify every original Swift source survived byte-for-byte.
 source_hashes={str(f.relative_to(source)):digest(f) for f in sorted((source/'Sources').rglob('*.swift'))}
 timeline_info=isolate_timeline(local,source_hashes)
 compiled_hashes={name:digest(local/name) for name in source_hashes}
 evidence={'upstream_revision':REV,'manifest_original_sha256':hashlib.sha256(original.encode()).hexdigest(),'manifest_adapted_sha256':digest(manifest),'adapter_sha256':hashlib.sha256(ADAPTER.encode()).hexdigest(),'renderer_files_changed':True,'original_swift_sha256':source_hashes,'compiled_swift_sha256':compiled_hashes,'timeline_isolation':timeline_info}
 (local/'LETTERPRESS_RESOURCE_ADAPTER.json').write_text(json.dumps(evidence,indent=2)+'\n')
 print(json.dumps(evidence,sort_keys=True))
if a.products:
 bundle=a.products/'Vortex_Vortex.bundle';bundle.mkdir(parents=True,exist_ok=True)
 for name,expected in PNG.items():
  f=local/'Sources/Vortex/Resources/Assets.xcassets'/(name+'.imageset')/(name+'.png')
  require(digest(f)==expected,'Original Vortex PNG hash mismatch: '+name)
  shutil.copy2(f,bundle/(name+'.png'))
 (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.letterpress.springboard.vortex-resources','CFBundleName':'Vortex_Vortex','CFBundlePackageType':'BNDL','CFBundleVersion':'1','CFBundleDevelopmentRegion':'en'}))
 print(json.dumps({'bundle':str(bundle),'original_png_sha256':PNG,'device_tested':False},indent=2))
else:print(json.dumps({'prepared_package':str(local),'revision':REV,'device_tested':False},indent=2))
