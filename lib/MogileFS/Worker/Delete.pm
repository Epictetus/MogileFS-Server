package MogileFS::Worker::Delete;
# deletes files

use strict;
use base 'MogileFS::Worker';

use POSIX ":sys_wait_h"; # argument for waitpid
use POSIX;

sub new {
    my ($class, $psock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($psock);

    return $self;
}

sub work {
    my $self = shift;

    my $sleep_for = 0; # we sleep longer and longer until we hit max_sleep
    my $sleep_max = 5; # max sleep when there's nothing to do.

  PASS:
    while (1) {
        $self->validate_dbh;
        my $dbh = $self->get_dbh;

        # see if we have anything from the parent
        my $start_time = time();
        my $end_time   = $start_time + 5;

        $self->get_orders_from_parent;

        # we select 1000 but only do a random 100 of them, to allow
        # for stateless paralleism
        my $LIMIT     = 1000;
        my $PER_BATCH = 100;

        while (1) {
            # report in to parent periodically
            next PASS if time() >= $end_time;

            my $delmap = $dbh->selectall_arrayref("SELECT fd.fid, fo.devid ".
                                                  "FROM file_to_delete fd ".
                                                  "LEFT JOIN file_on fo ON fd.fid=fo.fid ".
                                                  "LIMIT $LIMIT");
            my $count = $delmap ? scalar @$delmap : 0;
            unless ($count) {
                $sleep_for++ if $sleep_for < $sleep_max;
                sleep $sleep_for;
                next PASS;
            }
            $sleep_for = 0;

            my %dev_down;  # devid -> 1 (when device times out due to EIO)
            my $done = 0;
            foreach my $dm (List::Util::shuffle(@$delmap)) {
                my ($fid, $devid) = @$dm;

                # if no device is returned from the query above, that
                # means there are no file_on rows for it, and we can consider
                # it now deleted.
                unless (defined $devid) {
                    $dbh->do("DELETE FROM file_to_delete WHERE fid=?", undef, $fid);
                    next;
                }

                # don't try to delete from this device if we earlier
                # found it to be timing out with EIO
                next if $dev_down{$devid};

                last if ++$done > $PER_BATCH;

                my $path = make_path($devid, $fid);
                my $rv = 0;
                if (my $urlref = Mgd::is_url($path)) {
                    # hit up the server and delete it
                    my $sock = IO::Socket::INET->new(PeerAddr => $urlref->[0],
                                                     PeerPort => $urlref->[1],
                                                     Timeout => 2);
                    unless ($sock) {
                        # timeout or something, mark this device as down for now and move on
                        $dev_down{$devid} = 1;
                        next;
                    }

                    # send delete request
                    error("Sending delete for $path") if $Mgd::DEBUG >= 2;
                    $sock->write("DELETE $urlref->[2] HTTP/1.0\r\n\r\n");
                    my $response = <$sock>;  # FIXME: could hang
                    if ($response =~ m!^HTTP/\d+\.\d+\s+(\d+)!) {
                        if (($1 >= 200 && $1 <= 299) || $1 == 404) {
                            # effectively means all went well
                            $rv = 1;
                        } else {
                            # remote file system error?  mark node as down
                            error("Error: unlink failure: $path: $1");
                            $dev_down{$devid} = 1;
                            next;
                        }
                    } else {
                        error("Error: unknown response line: $response");
                    }
                } else {
                    # do normal unlink
                    $rv = unlink "$Mgd::MOG_ROOT/$path";

                    # device is timing out.  take note of it and
                    # continue dealing with other deletes
                    if (! $rv) {
                        if ($! == EIO) {
                            $dev_down{$devid} = 1;
                            next;
                        } elsif ($! == ENOENT) {
                            $rv = 1;  # count non-existent file as deleted
                        }
                    }
                }

                # if we deleted it, or it didn't exist, consider it
                # deleted.
                $dbh->do("DELETE FROM file_on WHERE fid=? AND devid=?",
                         undef, $fid, $devid) if $rv;
            }
        }
    }

}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End: