# docker-sdp-perforce-server-for-unreal-engine

Docker perforce server using SDP([Server Deployment Package](https://swarm.workshop.perforce.com/projects/perforce-software-sdp)), configured for Unreal Engine(a unicode, case-insensitive Perforce server with Unreal Engine's recommended Typemap).

## How to use

### 1. Get the Docker image

You can get the Docker image from Docker Hub or build it yourself.

* #### Use prebuilt image

You can use the prebuilt image from Docker Hub: [zhaojunmeng/sdp-perforce-server-for-unreal-engine](https://registry.hub.docker.com/r/zhaojunmeng/sdp-perforce-server-for-unreal-engine/)

* #### Build it yourself

In the project root directory, use the following command to build the image (using p4d version r23.1 as default).

```bash

docker build . -t sdp-perforce-server-for-unreal-engine:r23.1 --no-cache
    
```

If you want to run the container on NAS, you must save the image as a tar file, so you can upload it to the NAS.

```bash
docker save sdp-perforce-server-for-unreal-engine:r23.1 -o sdp-perforce-server-for-unreal-engine-r23.1.tar
```

Available --build-arg:
| ARG              | default value | meaning                                                                                                                                      |
| ---------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| UBUNTU_VERSION   | jammy         | Ubuntu version. Ensure this version is supported by Perforce. Check the official Perforce documentation for currently supported Ubuntu releases. |
| SDP_VERSION      | .2024.1.30385 | SDP version. It's recommended to check for the latest stable version from the Perforce website and update if building a new image.             |
| P4_VERSION       | r24.1         | P4 binaries version (Helix Core). It's recommended to check for the latest stable version from the Perforce website and update if building a new image. |
| P4_BIN_LIST      | p4,p4d        | Helix binaries to download. For minimal usage, only `p4` (client) and `p4d` (server) are needed.                                             |

Also you can tweak the .cfg files in the "files_for_run" folder, when you build your own image.

### 2. Run the container

Here's an example running on Docker Desktop.

To run the container from image, the following is required:

Ports: port to connect

Volumes: 4 folders to mount for "/hxmetadata", "/hxdepots", "/hxlogs", "/p4" on the container.(The 4 folders is explained here: [Volume Layout and Hardware](https://swarm.workshop.perforce.com/projects/perforce-software-sdp/view/main/doc/SDP_Guide.Unix.html#_volume_layout_and_hardware))

![Docker parameters](docs/images/RunningOnDockerDesktop_1.png)

After clicked "Run" button, see the Docker Logs and wait perforce server(p4d) to start in a few seconds.

![Logs output](docs/images/RunningOnDockerDesktop_2.png)

### 3. Connect to Perforce server

After the container's first setup, use [P4Admin](https://www.perforce.com/downloads/administration-tool) to login to Perforce to create new depots, groups and users.

>Server: the ip address or domain of your server, for Docker Desktop, it's 127.0.0.1:1666.
>
>User: the default and the only user is "perforce"(configured in p4-protect.cfg), enter the server ip

![Login as user perforce](docs/images/P4Admin_1.png)

After click "OK", you must change the initial password for user "perforce" (because the security level is set to 3, forcing an immediate password change).

**Initial Password for `perforce` user:**

Previously, a default password was set via the `P4_PASSWD` environment variable in the Dockerfile. This has been changed for better security.

*   **Automatic Password Generation**: If you do not set the `P4_PASSWD` environment variable when running `docker run`, a strong, random password will be automatically generated during the container's first startup.
*   **Check Docker Logs**: You **must** check the Docker logs for a message similar to this to retrieve the generated password:
    ```
    -----------------------------------------------------------------------
    IMPORTANT: The Perforce admin password is: your_generated_password_here
    -----------------------------------------------------------------------
    ```
*   **First Login**: Use this generated password when logging in as `perforce` for the first time with P4Admin. You will be required to change it immediately.

**Caution on setting `P4_PASSWD` manually:**
While you *can* still set a password using `docker run -e P4_PASSWD=yourchosenpassword ...`, this is generally discouraged for security reasons. Relying on the auto-generated password is safer for most use cases. If you do set it, that password will be used instead of a random one, and you will still be required to change it on first login.

![Change default password](docs/images/P4Admin_2.png)

After providing the initial password (either auto-generated or manually set) and then changing it, you can create new depots, groups, and users.

在群晖(NAS)上面如何运行，参考：[如何在群晖(NAS)上，部署一个为UnrealEngine定制的Perforce服务器](docs/HotToRunPerforceServerOnSynologyForUnrealEngine.md)

Enjoy!

## Disclaimer

I decline any responsibility in case of data loss or in case of a difficult (or even impossible) maintenance if you use this solution.  
I did this as a hobby for a small project.  
If you still want to use it for your project, I would suggest to setup or to do regularly backups of your project.
