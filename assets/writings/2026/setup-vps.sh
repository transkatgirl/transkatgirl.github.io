# Assumes your VPS service has a way to view the VM's graphical display
# Tested on Vultr with Ubuntu 25.10 w/ 30GB disk
# 12GB RAM recommended during setup, 4GB RAM & NVIDIA GPU recommended during usage

# Part 1
passwd && apt update && apt -y upgrade && apt install -y ubuntu-desktop && ubuntu-drivers install && ufw allow ssh && ufw enable && sed -i -e 's/auth	required	pam_succeed_if.so/#auth	required	pam_succeed_if.so/g' /etc/pam.d/gdm-password && sed -i -e 's/auth	required	pam_succeed_if.so/#auth	required	pam_succeed_if.so/g' /etc/pam.d/gdm-autologin && sed -i -e 's/#  AutomaticLoginEnable = true/AutomaticLoginEnable = true/g' -e 's/#  AutomaticLogin = user1/AutomaticLogin = root/g' /etc/gdm3/custom.conf && reboot

# Part 2
set -euxo pipefail

## OBS
apt install -y cmake extra-cmake-modules ninja-build pkg-config clang clang-format build-essential curl ccache git zsh libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev libavutil-dev libswresample-dev libswscale-dev libx264-dev libcurl4-openssl-dev libmbedtls-dev libgl1-mesa-dev libjansson-dev libluajit-5.1-dev python3-dev libx11-dev libxcb-randr0-dev libxcb-shm0-dev libxcb-xinerama0-dev libxcb-composite0-dev libxcomposite-dev libxinerama-dev libxcb1-dev libx11-xcb-dev libxcb-xfixes0-dev swig libcmocka-dev libxss-dev libglvnd-dev libgles2-mesa-dev libwayland-dev librist-dev libsrt-openssl-dev libpci-dev libpipewire-0.3-dev libqrcodegencpp-dev uthash-dev libsimde-dev qt6-base-dev qt6-base-private-dev qt6-svg-dev qt6-wayland qt6-image-formats-plugins libasound2-dev libfdk-aac-dev libfontconfig-dev libfreetype6-dev libjack-jackd2-dev libpulse-dev libsndio-dev libspeexdsp-dev libudev-dev libv4l-dev libva-dev libvlc-dev libvpl-dev libdrm-dev nlohmann-json3-dev libwebsocketpp-dev libasio-dev
git clone https://github.com/FFmpeg/nv-codec-headers.git
cd nv-codec-headers
make
sudo make install
cd ..
git clone --recursive https://github.com/obsproject/obs-studio.git
cd obs-studio
cmake --preset ubuntu-ci -DCMAKE_INSTALL_LIBDIR=lib -DENABLE_LIBFDK=ON -DENABLE_NVENC=ON
cmake --build build_ubuntu
cmake --install build_ubuntu
ldconfig
cd ..
mkdir ~/.config/autostart
cp obs-studio/frontend/cmake/linux/com.obsproject.Studio.desktop ~/.config/autostart

## Containers
apt install -y docker.io

### datagutt/bbox-receiver
git clone https://github.com/datagutt/bbox-receiver.git
cd bbox-receiver
docker build -t bbox-receiver .
cd ..
echo '{
  "auth": [
    {
      "user": "belabox",
      "key": "belabox"
    },
    {
      "user": "second_user",
      "key": "secret_key"
    }
  ]
}' > config.json
docker run --restart=always -d --name belabox-receiver -p 5000:5000/udp -p 8181:8181/tcp -p 8282:8282/udp -p 3000:3000/tcp -v $HOME/config.json:/app/config.json bbox-receiver
ufw allow 5000/udp

### MorrowShore/Prism
git clone https://github.com/MorrowShore/Prism.git
cd Prism
docker build -t prism .
cd ..
#docker run --restart=always -d -p 1935:1935 --name prism \
#	-e YOUTUBE_KEY="your-youtube-key" \
#	-e FACEBOOK_KEY="your-facebook-key" \
#	-e INSTAGRAM_KEY="your-instagram-key" \
#	-e TWITCH_URL="your-twitch-server" \
#	-e TWITCH_KEY="your-twitch-key" \
#	-e TROVO_KEY="your-trovo-key" \
#	-e KICK_KEY="your-kick-key" \
#	-e CLOUDFLARE_KEY="your-cf-key" \
#	-e INSTAGRAM_KEY="your-ig-key" \
#	-e RTMP1_URL="custom-rtmp1-server" \
#	-e RTMP1_KEY="custom-rtmp1-key" \
#	-e RTMP2_URL="custom-rtmp2-server" \
#	-e RTMP2_KEY="custom-rtmp2-key" \
#	-e RTMP3_URL="custom-rtmp3-server" \
#	-e RTMP3_KEY="custom-rtmp3-key" \
#	prism
