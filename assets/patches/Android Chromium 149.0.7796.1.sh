apt update && apt upgrade -y && apt install -y curl git lsb-release python3 git file vim sudo

git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="${HOME}/depot_tools:$PATH"
echo 'export PATH="${HOME}/depot_tools:$PATH"' > ~/.bashrc

mkdir ~/chromium && cd ~/chromium
#fetch --nohooks chromium
fetch --nohooks android
cd src

#echo "target_os = [ 'linux', 'android' ]" >> ../.gclient
#gclient sync

git checkout tags/149.0.7796.1
./build/install-build-deps.sh
gclient revert
gclient runhooks

git apply "~/Android Chromium 149.0.7796.1.patch"

ensure_bootstrap
gn args out/Default --args="target_os=\"android\" target_cpu=\"arm64\" use_remoteexec = false is_component_build = false"
autoninja -C out/Default chrome_public_apk