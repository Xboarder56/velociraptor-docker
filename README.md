# velociraptor-docker
Run [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) server with Docker

#### Install

- Ensure [docker-compose](https://docs.docker.com/compose/install/) is installed on the host
- `git clone https://github.com/weslambert/velociraptor-docker`
- `cd velociraptor-docker`
- Change credential values in `.env` as desired
- `docker-compose up` (or `docker-compose up -d` for detached)
- Access the Velociraptor GUI via https://\<hostip\>:8889 
  - Default u/p is `admin/admin`
  - This can be changed by running: 
  
  `docker exec -it velociraptor ./velociraptor --config server.config.yaml user add user1 user1 --role administrator`

### 🏗️ Building from Source

To build the image locally using this fork:

```bash
git clone https://github.com/Xboarder56/velociraptor-docker.git
cd velociraptor-docker
docker build -t xboarder56/velociraptor:latest .
```

You can also specify a particular version at build time:

```bash
docker build --build-arg VELOCIRAPTOR_VERSION=0.75.2 -t xboarder56/velociraptor:0.75.2 .
```

This allows you to rebuild images from specific Velociraptor versions while maintaining compatibility with your local configurations or custom base images.

#### Notes:

Linux, Mac, and Windows binaries are located in `/velociraptor/clients`, which should be mapped to the host in the `./velociraptor` directory if using `docker-compose`.  There should also be versions of each automatically repacked based on the server configuration.

Once started, edit `server.config.yaml` in `/velociraptor`, then run `docker-compose down/up` for the server to reflect the changes

#### Docker image
To pull only the Docker image:

`docker pull xboarder56/velociraptor`

To pull a specific version of the Docker image:

`docker pull xboarder56/velociraptor:0.75.1`

---

### 🧩 About This Fork

This repository is a fork of [weslambert/velociraptor-docker](https://github.com/weslambert/velociraptor-docker), originally created by **Wes Lambert**.  
It aims to maintain compatibility with the latest [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor) releases while providing additional configuration options and deployment improvements for Docker environments.

All credit for the foundational work goes to Wes Lambert — this fork primarily adds quality-of-life enhancements, updated configurations, and maintenance updates.

---

**Maintained by:** [Xboarder56](https://github.com/Xboarder56)  
**Upstream project:** [Velocidex Velociraptor](https://github.com/Velocidex/velociraptor)