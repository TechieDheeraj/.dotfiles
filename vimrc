call plug#begin()

"Navigation Plugins
Plug 'rbgrouleff/bclose.vim'
Plug 'dbakker/vim-projectroot'
Plug 'scrooloose/nerdtree'
Plug 'majutsushi/tagbar'

"UI Plugins
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'bling/vim-bufferline'
Plug 'altercation/vim-colors-solarized'

"Editor plugins
"Plug 'Valloric/YouCompleteMe', { 'do': './install.py --clangd-completer --go-completer --rust-completer --ts-completer' }
Plug 'airblade/vim-gitgutter'
Plug 'editorconfig/editorconfig-vim'

"Language specific
"Plug 'tmhedberg/SimpylFold', { 'for': 'python' }
Plug 'lervag/vimtex', { 'for': 'tex' }
Plug 'vhdirk/vim-cmake'
Plug 'ds26gte/scmindent'
"Plug 'fatih/vim-go'

"Note taking
Plug 'vimwiki/vimwiki'
Plug 'lukaszkorecki/workflowish'

Plug 'tpope/vim-fugitive'
Plug 'airblade/vim-gitgutter'
Plug 'editorconfig/editorconfig-vim'
"Plug 'jiangmiao/auto-pairs'
Plug 'patstockwell/vim-monokai-tasty'
Plug 'reewr/vim-monokai-phoenix'


call plug#end()

syntax on
filetype plugin indent on
colorscheme monokai-phoenix 
"colorscheme desert
set backspace=indent,eol,start

set softtabstop=4
set hlsearch
set ts=2
set sw=2
set number
set relativenumber
set expandtab
set ruler
set showcmd
set smartindent
set cindent
set autoindent
set mouse=a

" Uncomment the following to have Vim jump to the last position when
" reopening a file

if has("autocmd")
    au BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif

" C Template
autocmd BufNewFile *.c 0r ~/.vim/templates/template.c

" CPP Template
autocmd BufNewFile *.cpp 0r ~/.vim/templates/template.cpp

" Python Template
autocmd BufNewFile *.py 0r ~/.vim/templates/template.py

" Go Template
autocmd BufNewFile *.go 0r ~/.vim/templates/template.go

" Java Template
autocmd BufNewFile *.java 0r ~/.vim/templates/template.java

" Common Changes
autocmd BufNewFile *.cpp,*.py,*.c,*.go,*.java exe "1," . 10 . "g/file\ \ \ \ :/s//file    :  " .expand("%")
autocmd bufnewfile *.cpp,*.py,*.c,*.go,*.java exe "1," . 10 . "g/created\ :/s//created :  " .strftime("%Y %b %d %X")
autocmd bufnewfile *.cpp,*.py,*.c,*.go,*.java exe "1," . 10 . "g/lastMod\ :/s//lastMod :  " .strftime("%c")
autocmd bufnewfile *.java exe "1," . 10 . "g/class\ /s//class " .expand("%:r")
autocmd Bufwritepre,filewritepre *.cpp,*.py,*.c,*.go,*.java execute "normal ma"
