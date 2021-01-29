function printusage {
  echo "Usage: $0 -m <me_cleaner>(optional)"
}

BLOBDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$#" -eq 0 ]; then printusage; fi

while getopts ":m:" opt; do
  case $opt in
    m)
      if [ -x "$OPTARG" ]; then
        MECLEAN="$OPTARG"
      fi
      ;;
  esac
done

FINAL_ME_BIN_SHA256SUM="e985feb4a2879a99fb792f2d425c17a68ee07ba8bc0fd39a7f9eb65d8c6d5f11 $BLOBDIR/me.bin"
ME_SHA256SUM="1790fabc16afc36ab1bcfd52e10b805855d5e2a4eb96ea78781ffb60a0941928  me.bin"


if [ -z "$MECLEAN" ]; then
  MECLEAN=`command -v $BLOBDIR/../../build/coreboot-*/util/me_cleaner/me_cleaner.py 2>&1|head -n1`
  if [ -z "$MECLEAN" ]; then
    echo "me_cleaner.py required but not found or specified with -m. Aborting."
    exit 1;
  fi
fi

echo "### Creating temp dir"
extractdir=$(mktemp -d)
cd "$extractdir"

echo "### Downloading: https://github.com/coreboot/blobs/raw/master/mainboard/google/parrot/me.bin..."
wget  https://github.com/coreboot/blobs/raw/353f2469be53919b6b359148469485a9040e5a8b/mainboard/google/parrot/me.bin || ( echo "ERROR: wget not found" && exit 1 ) 
echo "### Verifying expected hash of me.bin"
echo "$ME_SHA256SUM" | sha256sum --check || ( echo "Failed sha256sum verification on downloaded binary..." && exit 1 )

echo "###Applying me_cleaner to neuter+deactivate+maximize reduction of ME on $bioscopy, outputting minimized ME under $BLOBDIR/me.bin... "
$MECLEAN -r -t -O "$BLOBDIR/me.bin" me.bin
echo "### Verifying expected hash of me.bin"
echo "$FINAL_ME_BIN_SHA256SUM" | sha256sum --check || ( echo "Failed sha256sum verification on final binary..." && exit 1 )


echo "###Cleaning up..."
cd - 
rm -r "$extractdir"
