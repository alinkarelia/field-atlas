"""Select an available Simulator matching the active Xcode SDK. No device deletion."""
import json,subprocess,sys
family=sys.argv[1]
if family not in ('iPhone','iPad'):raise SystemExit('Expected iPhone or iPad')
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],text=True).strip()
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json'],text=True))['devices']
runtime='com.apple.CoreSimulator.SimRuntime.iOS-'+sdk.replace('.','-')
available=[d for key,values in devices.items() if key==runtime for d in values if d.get('isAvailable') and d['name'].startswith(family)]
if not available:raise SystemExit('No available '+family+' Simulator for active SDK '+sdk)
selected=sorted(available,key=lambda d:(('Pro' not in d['name']),d['name']))[0]
print(selected['udid'])
