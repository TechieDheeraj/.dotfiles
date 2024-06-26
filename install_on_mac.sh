# Run this script to install all dotfiles on MacOS

echo -e "Installing tools \n"
#/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake
brew install tmux
brew install rectangle
brew install --cask scroll-reverser

echo -e "Copying all dotfiles \n"
cp -f ./bashrc_mac ~/.bashrc
ln -sf ~/.bashrc ~/.bash_profile
cp -f ./vimrc ~/.vimrc
cp -f ./screenrc ~/.screenrc
cp -f ./tmux.conf_mac ~/.tmux.conf 
cp -rf ./tmux ~/.tmux
mkdir -p ~/.vim 2>&1 > /dev/null
cp -rf ./vim/ ~/.vim
cd ~/.vim/headers/bits; /usr/bin/g++ --std=c++17 -w stdc++.h; cd -; 

echo -e "All Dotfiles Copied \n"
vim -c PlugInstall hello -c qa!
echo -e "Just Close the terminal and Open Again \n"
