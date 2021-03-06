#!/bin/bash

# This script provides a simple interface for folks to use the docker install

TAG=v0.21.0
if [ "$BLOCKSTACK_TAG" ]; then
   TAG="$BLOCKSTACK_TAG"
fi

CORETAG="$TAG-browser"

coreimage=quay.io/blockstack/blockstack-core:$CORETAG
browserimage=quay.io/blockstack/blockstack-browser:$TAG

if [ "$CORE_IMAGE" ]; then
    coreimage="$CORE_IMAGE"
fi

if [ "$BROWSER_IMAGE" ]; then
    browserimage="$BROWSER_IMAGE"
fi


# Default to setting blockstack to debug mode
if [ "$BLOCKSTACK_DEBUG" != "0" ]; then
    BLOCKSTACK_DEBUG=1
fi

# Local Blockstack directory
homedir=$HOME/.blockstack
# Name of Blockstack API container
corecontainer=blockstack-api
# Name of Blockstack Browser container
browsercontainer=blockstack-browser
# Local temporary directory
tmpdir=/tmp/.blockstack_tmp
if [ ! -e $tmpdir ]; then
   mkdir -p $tmpdir
fi
# set password blank so we know when to prompt
password=0

if [ "$WIN_HYPERV" == '1' ]; then
    coremount_tmp="/$tmpdir":'/tmp'
    coremount_home="/$homedir":'/root/.blockstack'
    client_ini='//root/.blockstack/client.ini'
    prefix='winpty'
else
    coremount_tmp="/$tmpdir":'/tmp'
    coremount_home="$homedir":'/root/.blockstack'
    client_ini='/root/.blockstack/client.ini'
    prefix=''
fi

build () {
  echo "Building blockstack docker image. This might take a minute..."
  docker build -t $browserimage .
}

create-wallet () {
  if [ $# -eq 0 ]; then
    echo "Need to input new wallet password when running setup: ./launcher create-wallet mypass"
    exit 1
  fi
  $prefix docker run -it -v $coremount_home $coreimage blockstack setup -y --password $1

  # Use init containers to set the API bind to 0.0.0.0
  $prefix docker run -it -v $coremount_home $coreimage sed -i 's/api_endpoint_bind = localhost/api_endpoint_bind = 0.0.0.0/' "$client_ini"
}

clear-registrar-lockfile () {
  # remove core's registrar lockfile. this can lead to problems if core starts up with the same
  # pid as an old version.
  $prefix docker run -it -v $coremount_home -v $coremount_tmp $coreimage rm -f /tmp/registrar.lock
}

start-containers () {
  # Check for args first
  if [ $# -ne 0 ]; then
      password=$1
  fi

  # let's see if we should create a new wallet
  if [ ! -e "$homedir/wallet.json" ]; then
    if [ $password == "0" ]; then
      prompt-new-password
    fi
    echo "Wallet does not exist yet. Setting up wallet"
    create-wallet $password
  fi

  # otherwise, prompt for an OLD password
  if [ $password == "0" ]; then
      prompt-password
  fi

  # Check for the blockstack-api container is running or stopped.
  if [ "$(docker ps -q -f name=$corecontainer)" ]; then
    echo "Blockstack core container is already running -- restarting it."
    stop
  elif [ ! "$(docker ps -q -f name=$corecontainer)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=$corecontainer)" ]; then
      # cleanup old container if its still around
      echo "removing old blockstack-core container..."
      docker rm $corecontainer
    fi

    # If there is no existing $corecontainer container, run one
    clear-registrar-lockfile
    docker run -dt --name $corecontainer -v $coremount_tmp -v $coremount_home -p 6270:6270 $coreimage bash

    if [ "$BLOCKSTACK_DEBUG" == "1" ]; then
      runcommand="blockstack api start --debug --password $password --api_password $password"
    else
      runcommand="blockstack api start --password $password --api_password $password"
    fi

    $prefix docker exec -it $corecontainer $runcommand
    curl -s http://localhost:6270/v1/ping | grep -q "alive"
    running=$?
    if [ $running -ne 0 ]; then
        echo "Failed to start Blockstack daemon -- is your password correct?"
        stop
        exit 1
    fi

  fi

  # Check for the blockstack-browser-* containers are running or stopped.
  if [ "$(docker ps -q -f name=$browsercontainer)" ]; then
    echo "Blockstack browser is already running -- restarting it."
    stop
  elif [ ! "$(docker ps -q -f name=$browsercontainer)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=$browsercontainer)" ]; then
      # cleanup old containers if they are still around
      echo "removing old browser containers..."
      docker rm $(docker ps -aq -f status=exited -f name=$browsercontainer)
    fi

    # If there are no existing blockstack-browser-* containers, run them
    docker run -d --name $browsercontainer-static -p 8888:8888 $browserimage blockstack-browser
    docker run -d --name $browsercontainer-cors  -e CORSPROXY_HOST="0.0.0.0" -p 1337:1337 $browserimage blockstack-cors-proxy

    if [[ $(uname) == 'Linux' ]]; then
      # let's register the protocol handler if it isn't already registered:
      create-linux-protocol-handler
      sensible-browser "http://localhost:8888/#coreAPIPassword=$password"
    elif [[ $(uname) == 'Darwin' ]]; then
      open "http://localhost:8888/#coreAPIPassword=$password"
    elif [[ $(uname) == 'Windows' || $(uname) == 'MINGW64_NT-10.0' ]]; then
      start "http://localhost:8888/#coreAPIPassword=$password"
    fi
  fi
}

stop () {
  bc=$(docker ps -a -f name=$browsercontainer -q)
  cc=$(docker ps -f name=$corecontainer -q)
  if [ ! -z "$cc" ]; then
    echo "stopping the running blockstack-api container"
    $prefix docker exec -dt $corecontainer blockstack api stop
    docker stop $cc
    docker rm $cc
  fi

  if [ ! -z "$bc" ]; then
    echo "stopping the running blockstack-browser containers"
    docker stop $bc
    docker rm $bc
  fi
}

enter () {
  echo "entering docker container"
  docker exec -it $browsercontainer-static /bin/bash
}

logs () {
  echo "streaming logs for blockstack-api container"
  docker logs $browsercontainer-static -f
}

push () {
  echo "pushing build container up to quay.io..."
  docker push $browserimage
}

commands () {
  cat <<-EOF

blockstack docker launcher commands:
  pull  -> fetch docker containers from quay
  start -> start the blockstack browser server
  stop  -> stop the blockstack browser server
  logs  -> access the logs from the blockstack browser server
  enter -> exec into the running docker container

To get started, use

 $  ./Blockstack-for-Linux.sh pull
 $  ./Blockstack-for-Linux.sh start

This *requires* Docker to run.

And this will start the environment for running the Blockstack Browser

Note: the Docker containers mount your /home/<user>/.blockstack directory

EOF
}

prompt-new-password () {
  cat <<EOF


Please enter a password to protect your Blockstack core node.
IMPORTANT: This will be used to encrypt information stored within the containers
           which may include private keys for your Blockstack wallet.
           It is important that you remember this password.
           This will be the password you use to "pair" your Blockstack Browser
           with your Blockstack core node.

           Legal characters:
               letters (upper and lowercase), numbers, '_', and '-'

EOF
  echo -n "Password: " ; read -s password ; echo
  echo -n "Repeat: " ; read -s password_repeated ; echo
  while [ ! $password == $password_repeated ] ; do
      echo "Passwords do not match, please try again."
      echo -n "Password: " ; read -s password ; echo
      echo -n "Repeat: " ; read -s password_repeated ; echo
  done
}

prompt-password () {
  echo "Enter your Blockstack Core password: " ; read -s password; echo
}

pull () {
    docker pull ${coreimage}
    docker pull ${browserimage}
}

version () {
    echo "Blockstack launcher tagged @ '$TAG'"
}

create-linux-protocol-handler () {
    HANDLER="blockstack.desktop"
    if [ ! -e "$HOME/.local/share/applications/$HANDLER" ]; then
       echo "Registering protocol handler"
       if [ ! -e "$HOME/.local/share/applications/" ]; then
          mkdir -p "$HOME/.local/share/applications/"
       fi
       cat - > "$HOME/.local/share/applications/$HANDLER" <<EOF
[Desktop Entry]
Type=Application
Terminal=false
Exec=bash -c 'xdg-open http://localhost:8888/auth?authRequest=\$(echo "%u" | sed s/blockstack://)'
Name=Blockstack-Browser
MimeType=x-scheme-handler/blockstack;
EOF
       chmod +x "$HOME/.local/share/applications/$HANDLER"
       xdg-mime default "$HANDLER" x-scheme-handler/blockstack
    fi
}

case $1 in
  create-linux-protocol-handler)
    create-linux-protocol-handler
    ;;
  stop)
    stop
    ;;
  create-wallet)
    create-wallet $2
    ;;
  start)
    start-containers $2
    ;;
  logs)
    logs
    ;;
  build)
    build
    ;;
  enter)
    enter
    ;;
  pull)
    pull
    ;;
  push)
    push
    ;;
  build)
    build
    ;;
  version)
    version
    ;;
  *)
    commands
    ;;
esac
