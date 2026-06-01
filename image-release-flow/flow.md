Build in jenkins

Copy to computer
```bash
scp -r ipat4@10.204.16.109:/var/lib/jenkins/jobs/qualcomm_yocto_scarthgap/builds/127/archive/release/v2.3.2 ./
```

Upload to R:// (S://)

```bash
rsync -avh --progress --partial /media/wilson/nvme_Wilson_Data1/image/EXMP-Q911/EXMP-Q911-fixWestonDP-v2.3.2/v2.3.2 /S/CrossFunction/IPA/Application/Qualcomm/Q911/
```