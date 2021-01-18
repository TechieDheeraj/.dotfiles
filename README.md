Prerequisite (Install or Upgrade):
    sudo apt-get update
    sudo apt-get upgrade vim 
    sudo apt-get upgrade vim-gtk 
    sudo apt-get upgrade vim-gnome 

PRE INSTALL:     

bashrc -----> cp ./bashrc ~/.bashrc                
tmux.conf --> cp ./tmux.conf ~/.tmux.conf           
vim --------> cp -rf ./vim ~/.vim          
vimrc ------> cp ./vimrc ~/.vimrc         
screenrc ------> cp ./screenrc ~/.screenrc

POST INSTALL:          

Open any file in Vim:

-> vim hello.txt               
-> :PlugInstall  # This Vim command will install all plugins mentioned in vimrc      

Tips:
    Use ":%y +" in vim (command mode) to copy whole file to system-clipboard
