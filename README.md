curl -fsSL https://raw.githubusercontent.com/KlemensasKaubrys/void_install/main/void.sh | bash -s -- \
  --disk /dev/sda \
  --efi-size 200MiB \
  --boot-size 500MiB \
  --hostname voidbox \
  --arch x86_64 \
  --repo https://repo-fi.voidlinux.org \
  --force
