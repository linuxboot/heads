This is a simple script permitting to go through each commit and try to get keys from randomly selected servers from a list.

- Individual key found are stored under keys/key_*
- Unfound key IDs are under not_found_keys.txt
- Unfound key users are under unfound_keys_users.txt

The last file is important, since it shows that some commits previously found cannot be verified.

As stated under https://github.com/linuxboot/heads/issues/1794#issuecomment-2389524366, one has to remember that for each git commit, the whole git tree is being signed by latest git commit signee.
But with public keys not being found easily from gpg key servers, some older commits with expired/revoked keys will look odd doing `git log --show-signature`
