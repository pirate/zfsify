# Back up elsewhere, convert, and restore

When your disk is at least half full, a temporary attached Volume or rclone remote
can hold the full backup while zfsify converts the source disk. Start the wizard:

```sh
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- --backup
```

Choose **1** for an attached Volume, **2** to configure a remote with rclone, or
**3** for an existing remote. Selecting **A** at the space warning opens the same
wizard. It waits while you prepare the destination; you can cancel with `q`.

```text
source disk -> backup on another disk / remote -> read-back checksum verification
            -> reformat source as ZFS -> restore files -> verify your server
```

## Temporary provider Volume

Choose a destination with free space for the source's used data plus overhead.
The wizard suggests used space plus 20%, rounded up in GB, as a starting estimate.
Compression can reduce the archive, but do not count on a particular ratio.

On **DigitalOcean**, open **Volumes → Add Volume**, choose the size and your
Droplet, then select **Automatically Format & Mount → Ext4** for the new empty
Volume. Use the mount directory displayed by the wizard, usually under `/mnt`.
See DigitalOcean's [creation guide](https://docs.digitalocean.com/products/volumes/how-to/create/)
and [mounting guide](https://docs.digitalocean.com/products/volumes/how-to/mount-unmount/).

On another provider, create and attach a disk in the server's region or
availability zone, then format the **new empty disk** as ext4 and mount it.
Follow its device identification instructions; device names vary:

- [Hetzner Volumes](https://docs.hetzner.com/cloud/volumes/overview/)
- [AWS EBS formatting and mounting](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-using-volumes.html) — select ext4 for this backup, even if an example uses XFS.

Keep the wizard open and use another SSH session if you need to mount the Volume
manually. Press Enter in the wizard to refresh its disk and free-space lists,
then enter the mounted directory. A plain directory on the source disk is not
enough: the backup must be on a **different physical disk with ext4**.

If it is already mounted, skip the wizard:

```sh
# Convert /; store the backup on the separate mounted Volume.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- \
  --backup=/mnt/zfsify_backup /

# Convert /mnt/data instead, keeping the same backup destination.
curl -fsSL https://pirate.github.io/zfsify/reformat.sh | sudo bash -s -- \
  --backup=/mnt/zfsify_backup /mnt/data
```

The positional path is the disk to **convert**; `--backup=` is the directory to
**store its backup**. Keep the backup Volume ext4 and attached through migration
and reboot. rclone copies to it locally; no S3 account or rclone remote is needed.

## S3, SFTP, and other rclone remotes

Choose **2** in the wizard to open [`rclone config`](https://rclone.org/commands/rclone_config/).
Create a remote with `n`, follow rclone's prompts, then use `q` to return to
zfsify. Enter a destination such as `myremote:zfsify-backups`; for S3 this includes
the bucket, for example `myremote:my-bucket/zfsify-backups`.
See rclone's [provider guides](https://rclone.org/overview/) for authentication and
storage-specific setup.

Existing configurations must be available to the **root user** running zfsify.
Use `sudo rclone config` when setting up separately, then pass
`--backup=myremote:bucket/path` for unattended use. Credentials must be contained
in rclone's configuration; external credential files are not supported. Encrypted
configurations can use `RCLONE_CONFIG_PASS`.

Use a private destination: the archive contains system configuration and
credentials. Allow bandwidth for the upload, a complete verification download,
and the restore download.

## After conversion

zfsify retains the archive in a unique `zfsify-...` folder. For root conversions,
the original destination, Volume UUID when applicable, and next steps are saved
in `/var/log/zfs-on-boot/backup-next-steps.txt`. For data-volume conversions, that
file is in the work/log directory printed by the installer.

Once the server boots from ZFS and you have checked your files and applications:

1. Keep the archive as a backup, or remove it when you no longer need it.
2. For a temporary Volume, unmount its actual mount directory. Remove any mount
   entry or systemd mount unit you created for it, if applicable.
3. Detach and delete the temporary Volume through your provider. On DigitalOcean,
   follow [detach and delete](https://docs.digitalocean.com/products/volumes/how-to/delete-detach/).
   Detaching alone does not stop storage charges.

The installer never deletes your backup destination automatically.
