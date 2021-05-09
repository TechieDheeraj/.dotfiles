# Run this script to install all dotfiles on MacOS

echo -e "Installing Dependent Packages\n"
sudo apt-get update
sudo apt-get install vim -y 
sudo apt-get install vim-gtk -y
sudo apt-get install vim-gnome -y 
sudo apt-get install cmake -y

echo -e "Copying all dotfiles \n"
cp -f ./bashrc ~/.bashrc
cp -f ./vimrc ~/.vimrc
cp -f ./screenrc ~/.screenrc
cp -f ./tmux.conf ~/.tmux.conf 
cp -rf ./vim ~/.vim
cd ~/.vim/headers/bits; /usr/bin/g++ -w stdc++.h; cd -; 

echo -e "All Dotfiles Copied \n"
vim -c PlugInstall hello -c qa!
echo -e "Just Close the terminal and Open Again \n"
