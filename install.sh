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

echo -e "All Dotfiles Copied \n"

echo -e "< Open Any file in Vim and Enter :PlugInstall in Command mode >\n"
echo -e "Just Close the terminal and Open Again \n"
