#!/usr/bin/env bash

set -euo pipefail;

# I'm experimenting with running an agent in a dedicated throwaway VM to keep
# it isolated from the rest of my system and to give it more autonomy. This
# script is to speed-up the initial "setup" of a new VM. Currently runs against
# a Debian Trixie install with the GNOME desktop and standard system utilities.
#
# 1. Install curl: sudo apt install curl
# 2. Run the script: bash -c "$(curl -fsSL https://mfgo.link/agentvm)"

GHIDRA_BASE=https://github.com/NationalSecurityAgency/ghidra/releases/download
GHIDRA_VERSION=Ghidra_12.2_build/ghidra_12.2_PUBLIC_20261016
NERDFONTS_BASE=https://github.com/ryanoasis/nerd-fonts/releases/download
NERDFONTS_VERSION=3.5.1

sudo echo -n

# install global tools
sudo apt-get install -y curl git htop magic-wormhole vim wget
sudo apt-get install -y 7zip imagemagick libarchive-tools openjdk-25-jdk
sudo apt-get install -y python3 python3-pip

echo "export EDITOR=vim" >> ~/.bashrc

# setup git
read -r -p "Enter your Git name: " git_name
read -r -p "Enter your Git email: " git_email

if [[ -z "$git_name" || -z "$git_email" ]]; then
  echo "Name and email can't be empty." >&2
  exit 1
fi

git config --global user.name "$git_name"
git config --global user.email "$git_email"

# download a nerdfont
mkdir -p ~/.local/share/fonts
wget ${NERDFONTS_BASE}/v${NERDFONTS_VERSION}/AdwaitaMono.zip
(
  cd ~/.local/share/fonts
  bsdtar xf ~/AdwaitaMono.zip
)
rm AdwaitaMono.zip
fc-cache -fv

# download ghidra (just tell the agent they can find ghidra in ~/Downloads)
wget $GHIDRA_BASE/$GHIDRA_VERSION.zip
mv "$(basename "$GHIDRA_VERSION.zip")" ~/Downloads
(
  cd ~/Downloads
  bsdtar xf "$(basename "$GHIDRA_VERSION.zip")"
)

# install build tools
sudo apt-get install -y binutils binwalk gcc make rustup
sudo apt-get install -y pkg-config libasound2-dev
sudo apt-get install -y dosbox-x
rustup default stable

# install oh-my-pi (this is a throwaway vm so `curl | sh` is ok...)
curl -fsSL https://omp.sh/install | sh
echo "export PATH=~/.local/bin:\$PATH" >> ~/.bashrc

# https://github.com/hakkm/omp-ntfy
echo "export NTFY_SERVER=http://192.168.123.1:8081" >> ~/.bashrc
echo "export NTFY_TOPIC=omp" >> ~/.bashrc
omp install npm:omp-ntfy

exit 0
