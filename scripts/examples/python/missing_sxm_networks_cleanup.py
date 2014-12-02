#!/usr/bin/env python

import os
import sys
import XenAPI
from missing_sxm_networks_create import login_to_host, confirm, magic_oc_key


def usage():
    name = os.path.basename(__file__)
    print "Usage: %s [-h|--help] <pool-master> <username> <password>" % name


def main(session):
    nets = session.xenapi.network.get_all_records()
    nets_to_clean = [x for x in nets if magic_oc_key in nets[x]["other_config"]]
    if not nets_to_clean:
        print "No networks in this pool need cleaning up."
        print "Exiting: nothing to do."
        sys.exit()
    net_names_to_clean = [nets[x]["name_label"] for x in nets_to_clean]
    confirm("This will DESTROY the following networks:\n"
            + "\t%s\n" % (net_names_to_clean)
            + "Do you wish to continue?")
    for net in nets_to_clean:
        print "Destroying network '%s'..." % net
        session.xenapi.network.destroy(net)
    print "Finished: Destroyed %d networks." % len(nets_to_clean)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "-h" in args or "--help" in args:
        usage()
        sys.exit()
    try:
        master, username, password = args
        master_session = login_to_host(master, username, password)
        main(master_session)
    except ValueError:
        usage()
        sys.exit(2)
    except XenAPI.Failure as e:
        print "Failed to create XenAPI session on host: %s" % e
        sys.exit(1)
