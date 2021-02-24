#!/usr/bin/env bash
set -e

# Install Google Chrome
curl -L https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo apt-key add -
sudo sh -c 'echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google.list'
sudo apt-get update
sudo apt-get install google-chrome-stable

# Install ChromeDriver
stable_version=`curl -L https://chromedriver.storage.googleapis.com/LATEST_RELEASE`
curl -L -O https://chromedriver.storage.googleapis.com/${stable_version}/chromedriver_linux64.zip
unzip chromedriver_linux64.zip
chmod +x chromedriver
sudo mv chromedriver /usr/local/bin/
