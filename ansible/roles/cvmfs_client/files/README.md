# The Repository public key lives here: nix.hayweb.org.pub, committed in cvmfs-service, so it ships
# inside the collection grmhay.cvmfs_service and every client run can read it. Nothing writes it here
# at run time: the Publisher's run prints it after mkfs, and an operator commits it, tags a release
# and re-vendors the collection (docs/runbooks/publisher-bootstrap.md, #17).
