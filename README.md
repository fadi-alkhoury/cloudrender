# Cloudrender: Render your 3D Blender model on the cloud with AWS EC2

`Cloudrender` allows you to render your [Blender](https://www.blender.org/) 3D project in the cloud with [AWS EC2](https://aws.amazon.com/ec2/).

Workflow
1. Run the cloudrender command.
2. The rendering is performed in the cloud.
3. The rendered images get transferred to your local machine.

There are costs associated with using AWS services. Refer to [Amazon EC2 Spot Instances Pricing](https://aws.amazon.com/ec2/spot/pricing/) to estimate the costs of your render jobs. The cost is around \$0.27 per hour, as of writing.

 By default, `cloudrender` uses `g4dn.xlarge` instances. You can choose the right instance type according to your needs, which can depend on whether you needs.


## One-time setup

You will first need to create an AMI for your render jobs. This involves launching an instance, installing Blender and drivers if needed, and then creating an AMI. T

The required drivers defer according to which instance type you plan to use.

**G4 Instance types**
Refer to the [instructions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/install-nvidia-driver.html#nvidia-GRID-driver) from AWS, for a full guide.

```
sudo apt-get update -y
sudo apt-get upgrade -y linux-aws

sudo reboot
sudo apt-get install -y gcc make linux-headers-$(uname -r)
cat << EOF | sudo tee --append /etc/modprobe.d/blacklist.conf
blacklist vga16fb
blacklist nouveau
blacklist rivafb
blacklist nvidiafb
blacklist rivatv
EOF

sudo vi /etc/default/grub 
# change to GRUB_CMDLINE_LINUX="rdblacklist=nouveau"
sudo update-grub

# install and setup the aws cli ( see setup_aws-cli.sh)

aws s3 cp --recursive s3://ec2-linux-nvidia-drivers/g4/latest/ .
chmod +x NVIDIA-Linux-x86_64*.run
ls /usr/lib/xorg/modules  # confirm this directory exists
sudo /bin/sh ./NVIDIA-Linux-x86_64*.run

nvidia-smi -q | head

rm NVIDIA-Linux-x86_64-440.87-grid-aws.run 
sudo reboot
```

**P2 and P3 Instance types**
```
sudo apt-get install linux-headers-$(uname -r)
distribution=$(. /etc/os-release;echo $ID$VERSION_ID | sed -e 's/\.//g')
sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/$distribution/x86_64/7fa2af80.pub
echo "deb http://developer.download.nvidia.com/compute/cuda/repos/$distribution/x86_64 /" | sudo tee /etc/apt/sources.list.d/cuda.list
sudo apt-get update
sudo apt-get -y install cuda-drivers

export PATH=/usr/local/cuda-11.0/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-11.0/lib\
                         ${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
                         
sudo systemctl enable nvidia-persistenced
sudo reboot

sudo nvidia-smi -pm 1

sudo reboot
```

Next, you need to install Blender on your instance.
    
```
sudo apt-get update -y
sudo apt-get install -y libx11-dev libxxf86vm-dev libxcursor-dev libxi-dev libxrandr-dev libxinerama-dev libglew-dev 
sudo snap install blender --classic
```

With blender now installed along with the needed drivers, you should finally create an AMI image from your instance. 

**IMPORTANT** Remember to terminate your instance (and spot request if applicable).

Add the configurations for your AMI in `settings.sh`.

To be able to run `cloudrender`, you will also need to setup the AWS CLI on your local machine (see `setup_aws-cli.sh`). 

[Optional] It is helpful to add an alias for cloudrender.sh so that you can use the script without always providing the full path.

## Rendering your project on the AWS could

- Make sure there aren't unnecessary files in your blender project. This helps reduce the upload time when sending your render job to EC2.
- Call `cloudrender` from the root of your blender project. You can provide the usual arguments for blender, in addition the instance type.

> cloudrender
>
> -c \<instanceType\> 
>
> &ensp; &ensp; &ensp; &ensp;Instance type
>
> -f \<frame\>
>
> &ensp; &ensp; &ensp; &ensp;The single frame which should be rendered
>
> -s \<startFrame\> 
>
> &ensp; &ensp; &ensp; &ensp;The start frame for rendering an animation (the -a option should be used)
>
> -e \<endFrame\> 
>
> &ensp; &ensp; &ensp; &ensp;The end frame for rendering an animation (the -a option should be used)
>
> -a  
>
> &ensp; &ensp; &ensp; &ensp;An animation should be rendered instead of a single frame
>

The results will be saved in `out/` after the render is complete. The EC2 instances should be automatically terminated by `cloudrender`, unless you interrupt the process.

---------------------------------------------------------------------------

## Possible Errors:

Here are some errors that may occur when running `cloudrender`. Any launched EC2 instances should still be terminated in case errors occur.

**MaxSpotInstanceCountExceeded error**
    
To resolve this error, either 
- Terminate your open spot requests. It may take a minute for the request to be closed.
- Make a request with AWS to increase the your limit

**Connection refused**

The ssh connection may potentially timeout sometimes. Simply the `cloudrender` command again.

---------------------------------------------------------------------------

## Limitations

Currently, the local host should stay up for the duration of the render and the `cloudrender` script should not be interrupted. 

One approach to avoid this limitation is to move the task of managing the EC2 render instance from the local machine to another "always up" cheap EC2 instance.
