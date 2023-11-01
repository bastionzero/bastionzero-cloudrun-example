FROM node:20-bullseye-slim

# Create and change to the app directory.
WORKDIR /usr/src/app

# Install zli (https://docs.bastionzero.com/docs/deployment/installing-the-zli,
# APT)
RUN apt-get update -y && apt-get install -y gnupg software-properties-common
RUN apt-key adv --keyserver keyserver.ubuntu.com \ 
--recv-keys E5C358E613982017 && add-apt-repository \
    'deb https://download-apt.bastionzero.com/production/apt-repo stable main'
RUN apt-get update -y && apt-get install -y zli && apt-get clean

# Install ssh client
RUN apt-get install -y openssh-client
# Create empty SSH config file
RUN mkdir -p /home/.ssh && touch /home/.ssh/config

# Copy application dependency manifests to the container image. A wildcard is
# used to ensure both package.json AND package-lock.json are copied. Copying
# this separately prevents re-running npm ci on every code change.
COPY package*.json ./

# Install dependencies.
RUN npm ci

# Copy local code to the container image.
COPY . .

# Run the web service on container startup.
CMD [ "npm", "start" ]