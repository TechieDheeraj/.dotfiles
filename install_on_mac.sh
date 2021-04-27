# Run this script to install all dotfiles on MacOS

echo -e "Installing CMake \n"
brew install cmake
echo -e "Copying all dotfiles \n"
cp -f ./bashrc_mac ~/.bashrc
ln -sf ~/.bashrc ~/.bash_profile
cp -f ./vimrc ~/.vimrc
cp -f ./screenrc ~/.screenrc
cp -f ./tmux.conf_mac ~/.tmux.conf 
cp -rf ./vim ~/.vim
echo -e "All Dotfiles Copied \n"

echo -e "< Open Any file in Vim and Enter :PlugInstall in Command mode >\n"
echo -e "Just Close the terminal and Open Again \n"
