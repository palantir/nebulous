#!/bin/bash
user="${1:-vagrant}"
# import rvm key and install ruby
if [[ ! $(su - ${user} -c 'ruby -v') ]]; then
  # seems like it currently installs the following packages:
  # patch, libyaml-devel, glibc-headers, autoconf, gcc-c++, glibc-devel, patch, readline-devel, zlib-devel, libffi-devel, openssl-devel, automake, libtool, bison, sqlite-devel
  su - ${user} -c 'command curl -sSL https://rvm.io/mpapis.asc | gpg --import -'
  su - ${user} -c 'curl -sSL https://get.rvm.io | bash -s stable --ruby'
  su - ${user} -c 'gem install bundler'
fi
# copy stuff to home dir because shared files are slow
su - ${user} -c 'cp -r /vagrant/* .'
su - ${user} -c 'bundle package --all'
su - ${user} -c 'bundle install --deployment --standalone'
