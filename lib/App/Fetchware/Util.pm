package App::Fetchware::Util;
# ABSTRACT: Miscelaneous functions for App::Fetchware.
###BUGALERT### Uses die instead of croak. croak is the preferred way of throwing
#exceptions in modules. croak says that the caller was the one who caused the
#error not the specific code that actually threw the error.
use strict;
use warnings;

use File::Spec::Functions qw(catfile catdir splitpath splitdir rel2abs
    file_name_is_absolute rootdir tmpdir);
use Path::Class;
use Net::FTP;
use HTTP::Tiny;
use Perl::OSType 'is_os_type';
use Cwd;
use App::Fetchware::Config ':CONFIG';
use File::Copy 'cp';
use File::Temp 'tempdir';
use File::stat;
use Fcntl qw(S_ISDIR :flock S_IMODE);
# Privileges::Drop only works on Unix, so only load it on Unix.
use if is_os_type('Unix'), 'Privileges::Drop';
use POSIX '_exit';
use Sub::Mage;
use URI::Split qw(uri_split uri_join);
use Text::ParseWords 'quotewords';
use Data::Dumper;

# Enable Perl 6 knockoffs, and use 5.10.1, because smartmatching and other
# things in 5.10 were changed in 5.10.1+.
use 5.010001;

# Set up Exporter to bring App::Fetchware::Util's API to everyone who use's it.
use Exporter qw( import );

our %EXPORT_TAGS = (
    UTIL => [qw(
        msg
        vmsg
        run_prog
        no_mirror_download_dirlist
        download_dirlist
        ftp_download_dirlist
        http_download_dirlist
        file_download_dirlist
        no_mirror_download_file
        download_file
        download_ftp_url
        download_http_url
        download_file_url
        do_nothing
        safe_open
        drop_privs
        write_dropprivs_pipe
        read_dropprivs_pipe
        create_tempdir
        original_cwd
        cleanup_tempdir
    )],
);

#        create_config_options

# *All* entries in @EXPORT_TAGS must also be in @EXPORT_OK.
our @EXPORT_OK = map {@{$_}} values %EXPORT_TAGS;








###BUGALERT### Add Test::Wrap support to msg() and vmsg() so that they will
#inteligently rewrap any text they receive so newly filled in variables won't
#screw up the wrapping.
sub msg (@) {

    # If fetchware was not run in quiet mode, -q.
    unless (defined $fetchware::quiet and $fetchware::quiet > 0) {
        # print are arguments. Use say if the last one doesn't end with a
        # newline. $#_ is the last subscript of the @_ variable.
        if ($_[$#_] =~ /\w*\n\w*\z/) {
            print @_;
        } else {
            say @_;
        }
    # Quiet mode is turned on.
    } else {
        # Don't print anything.
        return;
    }
}



sub vmsg (@) {

    # If fetchware was not run in quiet mode, -q.
    ###BUGALERT### Can I do something like:
    #eval "use constant quiet => 0;" so that the iffs below can be resolved at
    #run-time to make vmsg() and msg() faster???
    unless (defined $fetchware::quiet and $fetchware::quiet > 0) {
        # If verbose is also turned on.
        if (defined $fetchware::verbose and $fetchware::verbose > 0) {
            # print our arguments. Use say if the last one doesn't end with a
            # newline. $#_ is the last subscript of the @_ variable.
            if ($_[$#_] =~ /\w*\n\w*\z/) {
                print @_;
            } else {
                say @_;
            }
        }
    # Quiet mode is turned on.
    } else {
        # Don't print anything.
        return;
    }
}






###BUGALERT### Add support for dry-run functionality!!!!
sub run_prog {
    my (@args) = @_;

    # Kill weird "Insecure dependency in system while running with -T switch."
    # fatal exceptions by clearing the taint flag with a regex. I'm not actually
    # running in taint mode, but it bizarrely thinks I am.
    for my $arg (@args) {
        if ($arg =~ /(.*)/) {
            $arg = $1;
        } else {
            die <<EOD;
php.Fetchwarefile: Match anything pattern match failed! Huh! This shouldn't
happen, and is probably a bug.
EOD
        }
    }

    # Use Text::ParseWords quotewords() subroutine to deal with spliting the
    # arguments on whitespace, and to properly quote and keep single and double
    # quotes.
    my $program;
    ($program, @args) = map {quotewords('\s+', 1, $_)} @args;

    # If fetchware is run without -q.
    unless (defined $fetchware::quiet and $fetchware::quiet > 0) {
        local $" = '][';
        vmsg <<EOM;
Running command [$program] with options [@args].
EOM
        system($program, @args) == 0 or die <<EOD;
fetchware: run-time error. Fetchware failed to execute the specified program
[$program] with the arguments [@args]. The OS error was [$!], and the return
value was [@{[$? >> 8]}]. Please see perldoc App::Fetchware::Diagnostics.
EOD
    # If fetchware is run with -q.
    } else {
        # Use a piped open() to capture STDOUT, so that STDOUT is not printed to
        # the terminal like it usually is therby "quiet"ing it.
        # If not on Windows use safer open call that doesn't work on Windows.
        unless (is_os_type('Windows', $^O)) {
            open(my $fh, '-|', "$program", @args) or die <<EOD;
fetchware: run-time error. Fetchware failed to execute the specified program
while capturing its input to prevent it from being copied to the screen, because
you ran fetchware with it's --quite or -q option. The program was [$program],
and its arguments were [@args]. OS error [$!], and exit value [$?]. Please see
perldoc App::Fetchware::Diagnostics.
EOD
            # Close $fh, to cause perl to wait for the command to do its
            # outputing to STDOUT.
            close $fh;
        # We're on Windows.
        } else {
            open(my $fh, '-|', "$program @args") or die <<EOD;
fetchware: run-time error. Fetchware failed to execute the specified program
while capturing its input to prevent it from being copied to the screen, because
you ran fetchware with it's --quite or -q option. The program was [$program],
and its arguments were [@args]. OS error [$!], and exit value [$?]. Please see
perldoc App::Fetchware::Diagnostics.
EOD
            # Close $fh, to cause perl to wait for the command to do its
            # outputing to STDOUT.
            close $fh;
        }
    }
}






###BUGALERT### All download routines should be modified to use HTTP::Tiny's
#iterative download interface so I can write the downloaded files straight to
#disk to avoid wasting 20, 30 or 120gigs or so or whatever the file size is in
#memory for each downloaded file.


sub download_dirlist {
    my %opts;
    my $url;
    # One arg means its a $url.
    if (@_ == 1) {
       $url = shift;
    # More than one means it's a PATH, and if it's not a path...
    } elsif (@_ == 2) {
        %opts = @_;
        # Or your param wasn't PATH
        if (not exists $opts{PATH} and not defined $opts{PATH}) {
            # Use goto for cool old-school C-style error handling to avoid copy
            # and pasting or insane nested ifs.
            goto PATHERROR;
        }
    # ...then it's an error.
    } else {
        PATHERROR: die <<EOD;
App-Fetchware-Util: You can only specify either PATH or URL never both. Only
specify one or the other when you call download_dirlist().
EOD
    }

    # Ensure the user has specified a mirror, because otherwise download_file()
    # will try to just download a path, and that's not going to work.
    die <<EOD if not config('mirror') and exists $opts{PATH};
App-Fetchware-Util: You only called download_dirlist() with just a PATH
parameter, but also failed to specify any mirrors in your configuration. Without
any defined mirrors download_dirlist() cannot determine from what host to
download your file. Please specify a mirror and try again.
EOD

    # Set up our list of urls that we'll try to download the specified PATH or
    # URL from.
    my @urls = config('mirror');
    # Add lookup_url's hostname to @urls as a last resort for ftp:// and
    # http:// URLs, and to allow file:// URLs to work, because oftentimes
    # specifying a mirror when using a local file:// URL makes no sense, and
    # requiring users to copy and paste the hostname of their lookup_url into a
    # mirror option is silly.
use Test::More;
    my ($scheme, $auth, undef, undef, undef) =
        uri_split(config('lookup_url'));
    # Skip adding the "hostname" for local (file://) url's, because they don't
    # have a hostname.
    if ($scheme ne 'file') {
        push @urls, uri_join($scheme, $auth, undef, undef, undef);
    }
    if (exists $opts{PATH}
        and defined $opts{PATH}
        and $opts{PATH}) {
        # The PATH option means that $url is not a full blown URL, but just a
        # path without a hostname or scheme portion.
        # Therefore, we append $url, because the PATH option means it's actually
        # just a path, so we append it to each @url.
        for my $mirror_url (@urls) {
            # Use URI to replace the current path with the one the caller
            # specified in the $url parameter.
            my ($scheme, $auth, undef, undef, undef) = uri_split($mirror_url);
            $mirror_url = uri_join($scheme, $auth, $opts{PATH}, undef, undef);
        }
    } elsif (defined $url
        and $url) {
        # Add $url to @urls since it too has a hostname. And use unshift
        # to put it in the first position instead of last if you were to use
        # push.
        unshift @urls, $url;

        # I must parse out the path portion of the specified URL, because this
        # path portion will be appended to the mirrors you have specified.
        my $url_path = ( uri_split($url) )[2];
        for my $mirror_url (@urls) {
            # If the $mirror_url has no path...
                my ($scheme, $auth, $path, $query, $frag) =
                    uri_split($mirror_url);
            if ($path eq '') {
                #...then append $url's path.
                ###BUGALERT## As shown before I was using URI's much nicer
                #interface, but it was deleting the path instead of replacing
                #the path! I tried reproducing this with a small test file, but
                #it worked just fine in the small test file. So, it must be some
                #really weird bug to fail here, but work in a smaller test file.
                #I don't know try replacing all of the URI::Split calls with the
                #equivelent URI->path() calls, and you'll get the weird bug.
                #$mirror_url->path($url_path);
                $mirror_url =
                    uri_join($scheme, $auth, $url_path, $query, $frag);
            # But if the $mirror_url does have a path...
            } else {
                #...Then keep the mirrors path intact.
                #
                # Because if you specify a path when you define that mirror
                # chances are you did it, because that mirror stores it in a
                # different directory. For example Apache is /apache on some
                # mirrors, but apache.hostname on other mirrors.
            }
        }
    }

    my $dirlist;

    for my $mirror_url (@urls) {
        eval {
            msg "Attempting to download [$mirror_url].";
            # Try the mirror_url directly without trying any mirrors.
            $dirlist = no_mirror_download_dirlist($mirror_url);
        };
        if ($@) {
            msg "Directory download attempt failed! Error was[";
            print $@;
            msg "].";
        }

        # Skip the rest of the @urls after we successfully download the $url.
        if (defined $dirlist) {
            msg "Successfully downloaded the directory listing.";
            last;
        }
    }

    die <<EOD if not defined $dirlist;
App-Fetchware-Util: Failed to download the specifed URL [$url] or path
[$opts{PATH}] using the included hostname in the url you specifed or any
mirrors. The mirrors are [@{[config('mirror')]}]. And the urls
that fetchware tried to download were [@urls].
EOD

    return $dirlist;
}



sub no_mirror_download_dirlist {
    my $url = shift;

    my $dirlist;
    if ($url =~ m!^ftp://.*$!) {
        $dirlist = ftp_download_dirlist($url);
    } elsif ($url =~ m!^http://.*$!) {
        $dirlist = http_download_dirlist($url);
    } elsif ($url =~ m!^file://.*$!) {
      $dirlist = file_download_dirlist($url);
    } else {
        die <<EOD;
App-Fetchware: run-time syntax error: the url parameter your provided in
your call to download_dirlist() [$url] does not have a supported URL scheme (the
http:// or ftp:// part). The only supported download types, schemes, are FTP and
HTTP. See perldoc App::Fetchware.
EOD
    }

    return $dirlist;
}



sub ftp_download_dirlist {
    my $ftp_url = shift;
    $ftp_url =~ m!^ftp://([-a-z,A-Z,0-9,\.]+)(/.*)?!;
    my $site = $1;
    my $path = $2;

    # Add debugging later based on fetchware commandline args.
    # for debugging: $ftp = Net::FTP->new('$site','Debug' => 10);
    # open a connection and log in!
    my $ftp;
    $ftp = Net::FTP->new($site)
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to connect to the ftp server at
domain [$site]. The system error was [$@].
See man App::Fetchware.
EOD

    $ftp->login("anonymous",'-anonymous@')
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to log in to the ftp server at
domain [$site]. The ftp error was [@{[$ftp->message]}]. See man App::Fetchware.
EOD


    my @dir_listing = $ftp->dir($path)
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to get a long directory listing
of [$path] on server [$site]. The ftp error was [@{[$ftp->message]}]. See man App::Fetchware.
EOD

    $ftp->quit();

    return \@dir_listing;
}



sub http_download_dirlist {
    my $http_url = shift;

    # Forward any other options over to HTTP::Tiny. This is used mostly to
    # support changing user agent strings, but why not support them all.
    my %opts = @_ if @_ % 2 == 0;

    # Append user_agent if specified.
    $opts{agent} = config('user_agent') if config('user_agent');

    my $http = HTTP::Tiny->new(%opts);
    ###BUGALERT### Should use request() instead of get, because request can
    #directly write the chunks of the file to disk as they are downloaded. get()
    #just uses RAM, so a 50Meg file takes up 50 megs of ram, and so on.
    my $response = $http->get($http_url);

    die <<EOD unless $response->{success};
App-Fetchware: run-time error. HTTP::Tiny failed to download a directory listing
of your provided lookup_url. HTTP status code [$response->{status} $response->{reason}]
HTTP headers [@{[Data::Dumper::Dumper($response->{headers})]}].
See man App::Fetchware.
EOD


    while (my ($k, $v) = each %{$response->{headers}}) {
        for (ref $v eq 'ARRAY' ? @$v : $v) {
        }
    }

    die <<EOD unless length $response->{content};
App-Fetchware: run-time error. The lookup_url you provided downloaded nothing.
HTTP status code [$response->{status} $response->{reason}]
HTTP headers [@{[Data::Dumper::Dumper($response)]}].
See man App::Fetchware.
EOD
    return $response->{content};
}



sub file_download_dirlist {
    my $local_lookup_url = shift;

    $local_lookup_url =~ s!^file://!!; # Strip scheme garbage.

    # Prepend original_cwd() if $local_lookup_url is a relative path.
    unless (file_name_is_absolute($local_lookup_url)) {
        $local_lookup_url =  catdir(original_cwd(), $local_lookup_url);
    }

    # Throw an exception if called with a directory that does not exist.
    die <<EOD if not -e $local_lookup_url;
App-Fetchware-Util: The directory that fetchware is trying to use to determine
if a new version of the software is available does not exist. This directory is
[$local_lookup_url], and the OS error is [$!].
EOD


    my @file_listing;
    opendir my $dh, $local_lookup_url or die <<EOD;
App-Fetchware-Util: The directory that fetchware is trying to use to determine
if a new version of the software is availabe cannot be opened. This directory is
[$local_lookup_url], and the OS error is [$!].
EOD
    while (my $filename = readdir($dh)) {
        # Trim the useless '.' and '..' Unix convention fake files from the listing.
        unless ($filename eq '.' or $filename eq '..') {
            # Turn the relative filename into a full pathname.
            #
            # Full pathnames are required, because lookup()'s
            # file_parse_filelist() stat()s each file using just their filename,
            # and if it's relative instead of absolute these stat() checks will
            # fail.
            my $full_path = catfile($local_lookup_url, $filename);
            push @file_listing, $full_path;
        }
    }

    closedir $dh;

    # Throw another exception if the directory contains nothing.
    # Awesome, clever, and simple Path::Class based "is dir empty" test courtesy
    # of tobyinc on PerlMonks (http://www.perlmonks.org/?node_id=934482).
    my $pc_local_lookup_url = dir($local_lookup_url);
    die <<EOD if $pc_local_lookup_url->stat() && !$pc_local_lookup_url->children();
App-Fetchware-Util: The directory that fetchware is trying to use to determine
if a new version of the software is available is empty. This directory is
[$local_lookup_url].
EOD

    return \@file_listing;
}




###BUGALERT###I'm a 190 line disaster! Please refactor me. Oh, and
#download_dirlist() too please, because I'm just a copy and paste of that
#subroutine!
sub download_file {
    my %opts;
    my $url;
    # One arg means its a $url.
    if (@_ == 1) {
       $url = shift;
    # More than one means it's a PATH, and if it's not a path...
    } elsif (@_ == 2) {
        %opts = @_;
        # Or your param wasn't PATH
        if (not exists $opts{PATH} and not defined $opts{PATH}) {
            # Use goto for cool old-school C-style error handling to avoid copy
            # and pasting or insane nested ifs.
            goto PATHERROR;
        }
    # ...then it's an error.
    } else {
        PATHERROR: die <<EOD;
App-Fetchware-Util: You can only specify either PATH or URL never both. Only
specify one or the other when you call download_file().
EOD
    }

    # Ensure the user has specified a mirror, because otherwise download_file()
    # will try to just download a path, and that's not going to work.
    if (not config('mirror') and exists $opts{PATH}
        and (config('lookup_url') !~ m!^file://!)) {
        die <<EOD ;
App-Fetchware-Util: You only called download_file() with just a PATH parameter,
but also failed to specify any mirrors in your configuration. Without any
defined mirrors download_file() cannot determine from what host to download your
file. Please specify a mirror and try again.
EOD
    }

    # Set up our list of urls that we'll try to download the specified PATH or
    # URL from.
    my @urls = config('mirror');
    # If we're called with a PATH option and the lookup_url is for a local file,
    # then we should just convert from a PATH into a $url.
    if (exists $opts{PATH} and config('lookup_url') =~ m!^file://!) {
        $url = "file://$opts{PATH}";
        delete $opts{PATH};
    # Otherwise, we should add lookup_url's hostname to the list of mirrors, but
    # be sure to push it onto @urls so that it is used last.
    #
    # But only if lookup_url is defined.
    } elsif (defined config('lookup_url')) {
        my ($scheme, $auth, undef, undef, undef) =
            uri_split(config('lookup_url'));
        push @urls, uri_join($scheme, $auth, undef, undef, undef);
    }

    if (exists $opts{PATH}
        and defined $opts{PATH}
        and $opts{PATH}) {
        # The PATH option means that $url is not a full blown URL, but just a
        # path without a hostname or scheme portion.
        # Therefore, we append $url, because the PATH option means it's actually
        # just a path, so we append it to each @url.
        for my $mirror_url (@urls) {
            # If the $mirror_url has no path...
            my ($scheme, $auth, $path, $query, $frag) =
                uri_split($mirror_url);
            # Skip messing with the path if $path eq $opts{PATH}, which means the
            # current $mirror_url is $url, so we shouldn't add its own path to
            # itself--we should skip it instead.
            next if $path eq $opts{PATH};
            if ($path eq '') {
                #...then append $url's path.
                ###BUGALERT## As shown before I was using URI's much nicer
                #interface, but it was deleting the path instead of replacing
                #the path! I tried reproducing this with a small test file, but
                #it worked just fine in the small test file. So, it must be some
                #really weird bug to fail here, but work in a smaller test file.
                #I don't know try replacing all of the URI::Split calls with the
                #equivelent URI->path() calls, and you'll get the weird bug.
                #$mirror_url->path($opts{PATH});
                ###Add an unless ($opts{PATH} eq '')
                $mirror_url =
                    uri_join($scheme, $auth, $opts{PATH}, $query, $frag);
            # But if the $mirror_url does have a path...
            } else {
                #...Then keep the mirrors path intact.
                #
                # Because if you specify a path when you define that mirror
                # chances are you did it, because that mirror stores it in a
                # different directory. For example Apache is /apache on some
                # mirrors, but apache.hostname on other mirrors.
                #
                #Except add $path's basename, because otherwise we'll ask
                #for a dirlisting or try to download a directory as a file.
                unless ($path =~ m!/$!) {
                    $mirror_url = 
                        uri_join($scheme, $auth, $path . '/'
                            . file($opts{PATH})->basename(), $query, $frag);
                # Skip adding a '/' if ones already there at the end.
                } else {
                    $mirror_url = 
                        uri_join($scheme, $auth, $path
                            . file($opts{PATH})->basename(), $query, $frag);
                }
            }
        }
    } elsif (defined $url
        and $url) {
        # Add $url to @urls since it too has a hostname. And use unshift
        # to put it in the first position instead of last if you were to use
        # push.
        unshift @urls, $url;

        # I must parse out the path portion of the specified URL, because this
        # path portion will be appended to the mirrors you have specified.
        my $url_path = ( uri_split($url) )[2];
        for my $mirror_url (@urls) {
            # If the $mirror_url has no path...
            my ($scheme, $auth, $path, $query, $frag) =
                uri_split($mirror_url);
            # Skip messing with the path if $path eq $url_path, which means the
            # current $mirror_url is $url, so we shouldn't add its own path to
            # itself--we should skip it instead.
            next if $path eq $url_path;
            if ($path eq '') {
                #...then append $url's path.
                ###BUGALERT## As shown before I was using URI's much nicer
                #interface, but it was deleting the path instead of replacing
                #the path! I tried reproducing this with a small test file, but
                #it worked just fine in the small test file. So, it must be some
                #really weird bug to fail here, but work in a smaller test file.
                #I don't know try replacing all of the URI::Split calls with the
                #equivelent URI->path() calls, and you'll get the weird bug.
                #$mirror_url->path($url_path);
                ###Add an unless ($url_path eq '')
                $mirror_url =
                    uri_join($scheme, $auth, $url_path, $query, $frag);
            # But if the $mirror_url does have a path...
            } else {
                #...Then keep the mirrors path intact.
                #
                # Because if you specify a path when you define that mirror
                # chances are you did it, because that mirror stores it in a
                # different directory. For example Apache is /apache on some
                # mirrors, but apache.hostname on other mirrors.
                #
                #Except add $path's basename, because otherwise we'll ask
                #for a dirlisting or try to download a directory as a file.
                unless ($path =~ m!/$!) {
                    $mirror_url = 
                        uri_join($scheme, $auth, $path . '/'
                            . file($url_path)->basename(), $query, $frag);
                # Skip adding a '/' if ones already there at the end.
                } else {
                    $mirror_url = 
                        uri_join($scheme, $auth, $path
                            . file($url_path)->basename(), $query, $frag);
                }
            }
        }
    }

    my $filename;

    for my $mirror_url (@urls) {
        eval {
            msg "Attempting to download [$mirror_url].";
            # Try the mirror_url directly without trying any mirrors.
            $filename = no_mirror_download_file($mirror_url);
        };
        if ($@) {
            msg "File download attempt failed! Error was[";
            print $@;
            msg "].";
        }

        # Skip the rest of the @urls after we successfully download the $url.
        if (defined $filename) {
            msg "Successfully downloaded the file [$mirror_url].";
            last;
        }
    }

    die <<EOD if not defined $filename;
App-Fetchware-Util: Failed to download the specifed URL [$url] or path
[$opts{PATH}] using the included hostname in the url you specifed or any
mirrors. The mirrors are [@{[config('mirror')]}]. And the urls
that fetchware tried to download were [@{[@urls]}].
EOD

    return $filename;
}



sub no_mirror_download_file {
    my $url = shift;

    my $filename;
    if ($url =~ m!^ftp://!) {
        $filename = download_ftp_url($url);
    } elsif ($url =~ m!^http://!) {
        $filename = download_http_url($url);
    } elsif ($url =~ m!^file://!) {
        $filename = download_file_url($url);   
    } else {
        die <<EOD;
App-Fetchware: run-time syntax error: the url parameter your provided in
your call to download_file() [$url] does not have a supported URL scheme (the
http:// or ftp:// part). The only supported download types, schemes, are FTP and
HTTP. See perldoc App::Fetchware.
EOD
    }

    return $filename;
}



sub download_ftp_url {
    my $ftp_url = shift;

    ###BUGALERT### Replace custom regex with URI::Split's regex.
    $ftp_url =~ m!^ftp://([-a-z,A-Z,0-9,\.]+)(/.*)?!;
    my $site = $1;
    my $path = $2;
    my ($volume, $directories, $file) = splitpath($path);

    # for debugging: $ftp = Net::FTP->new('site','Debug',10);
    # open a connection and log in!

    my $ftp = Net::FTP->new($site)
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to connect to the ftp server at
domain [$site]. The system error was [$@].
See man App::Fetchware.
EOD
    
    $ftp->login("anonymous",'-anonymous@')
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to log in to the ftp server at
domain [$site]. The ftp error was [@{[$ftp->message]}]. See man App::Fetchware.
EOD

    # set transfer mode to binary
    $ftp->binary()
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to swtich to binary mode while
trying to download a the file [$path] from site [$site]. The ftp error was
[@{[$ftp->message]}]. See perldoc App::Fetchware.
EOD

    # change the directory on the ftp site
    $ftp->cwd($directories)
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to cwd() to [$path] on site
[$site]. The ftp error was [@{[$ftp->message]}]. See perldoc App::Fetchware.
EOD


    # Download the file to the current directory. The start() subroutine should
    # have cd()d to a tempdir for fetchware to use.
    $ftp->get($file)
        or die <<EOD;
App-Fetchware: run-time error. fetchware failed to download the file [$file]
from path [$path] on server [$site]. The ftp error message was
[@{[$ftp->message]}]. See perldoc App::Fetchware.
EOD

    # ftp done!
    $ftp->quit;

    # The caller needs the $filename to determine the $package_path later.
    return $file;
}



sub download_http_url {
    my $http_url = shift;

    # Forward any other options over to HTTP::Tiny. This is used mostly to
    # support changing user agent strings, but why not support them all.
    my %opts = @_ if @_ % 2 == 0;

    # Append user_agent if specified.
    $opts{agent} = config('user_agent') if config('user_agent');

    my $http = HTTP::Tiny->new(%opts);
    ###BUGALERT### Should use request() instead of get, because request can
    #directly write the chunks of the file to disk as they are downloaded. get()
    #just uses RAM, so a 50Meg file takes up 50 megs of ram, and so on.
    my $response = $http->get($http_url);

#use Test::More;
#diag("RESPONSE OBJECT[");
#diag explain $response->{status};
#diag explain $response->{headers};
#diag explain $response->{url};
#diag explain $response->{reason};
#diag explain $response->{success};
## Should be commented out to avoid borking the terminal, but is needed when
## HTTP::Tiny has internal 599 errors, because the error message is in the
## content.
##diag explain $response->{content}; 
#diag("]");

    die <<EOD unless $response->{success};
App-Fetchware: run-time error. HTTP::Tiny failed to download a file or directory
listingfrom your provided url [$http_url]. HTTP status code
[$response->{status} $response->{reason}] HTTP headers
[@{[Data::Dumper::Dumper($response->{headers})]}].
See man App::Fetchware.
EOD

    # In this case the content is binary, so it will mess up your terminal.
    #diag($response->{content}) if length $response->{content};
    die <<EOD unless length $response->{content};
App-Fetchware: run-time error. The url [$http_url] you provided downloaded
nothing.  HTTP status code [$response->{status} $response->{reason}]
HTTP headers [@{[Data::Dumper::Dumper($response)]}].
See man App::Fetchware.
EOD

    # Must convert the worthless $response->{content} variable into a real file
    # on the filesystem. Note: start() should have cd()d us into a suitable
    # tempdir.
    my $path = $http_url;
    $path =~ s!^http://!!;
    # Determine filename from the $path.
    my ($volume, $directories, $filename) = splitpath($path);
    # If $filename is empty string, then its probably a index directory listing.
    $filename ||= 'index.html';
    ###BUGALERT### Need binmode() on Windows???
    ###BUGALERT### Switch to safe_open()????
    open(my $fh, '>', $filename) or die <<EOD;
App-Fetchware: run-time error. Fetchware failed to open a file necessary for
fetchware to store HTTP::Tiny's output. Os error [$!]. See perldoc
App::Fetchware.
EOD
    # Write HTTP::Tiny's downloaded file to a real file on the filesystem.
    print $fh $response->{content};
    close $fh
        or die <<EOS;
App-Fetchware: run-time error. Fetchware failed to close the file it created to
save the content it downloaded from HTTP::Tiny. This file was [$filename]. OS
error [$!]. See perldoc App::Fetchware.
EOS

    # The caller needs the $filename to determine the $package_path later.
    return $filename;
}




sub download_file_url {
    my $url = shift;

    $url =~ s!^file://!!; # Strip useless URL scheme.
    
    # Prepend original_cwd() only if the $url is *not* absolute, which will mess
    # it up.
    $url = catdir(original_cwd(), $url) unless file_name_is_absolute($url);

    # Download the file:// URL to the current directory, which should already be
    # in $temp_dir, because of start()'s chdir().
    #
    # Don't forget to clear taint. Fetchware does *not* run in taint mode, but
    # for some reason, bug?, File::Copy checks if data is tainted, and then
    # retaints it if it is already tainted, but for some reason I get "Insecure
    # dependency" taint failure exceptions when drop priving. The fix is to
    # always untaint my data as done below.
    ###BUGALERT### Investigate this as a possible taint bug in perl or just
    #File::Copy. Perhaps the cause is using File::Copy::cp(copy) after drop
    #priving with data from root?
    $url =~ /(.*)/;
    my $untainted_url = $1;
    my $cwd = cwd();
    $cwd =~ /(.*)/;
    my $untainted_cwd = $1;
    cp($untainted_url, $untainted_cwd) or die <<EOD;
App::Fetchware: run-time error. Fetchware failed to copy the download URL
[$untainted_url] to the working directory [$untainted_cwd]. Os error [$!].
EOD

    # Return just file filename of the downloaded file.
    return file($url)->basename();
}







###BUGALERT### safe_open() does not check extended file perms such as ext*'s
#crazy attributes, linux's (And other Unixs' too) MAC stuff or Windows NT's
#crazy file permissions. Could use Win32::Perms for just Windows, but its not
#on CPAN. And what about the other OSes.
###BUGALERT### Consier moving this to CPAN??? File::SafeOpen????
sub safe_open {
    my $file_to_check = shift;
    my $open_fail_message = shift // <<EOE;
Failed to open file [$file_to_check]. OS error [$!].
EOE

    my %opts = @_;

    my $fh;


    # Open the file first.
    unless (exists $opts{MODE} and defined $opts{MODE}) {
        open $fh, '<', $file_to_check or die $open_fail_message;
    } else {
        open $fh, $opts{MODE}, $file_to_check or die $open_fail_message;
    }

    my $info = stat($fh);# or goto STAT_ERROR;

    # Owner must be either me (whoever runs fetchware) or superuser. No one else
    # can be trusted.
    if(($info->uid() != 0) && ($info->uid() != $<)) {
        die <<EOD;
App-Fetchware-Util: The file fetchware attempted to open is not owned by root or
the person who ran fetchware. This means the file could have been dangerously
altered, or it's a simple permissions problem. Do not simly change the
ownership, and rerun fetchware. Please check that the file [$file_to_check] has
not been tampered with, correct the ownership problems and try again.
EOD
    }

    # Check if group and other can write $fh.
    # Use 066 to detect read or write perms.
    ###BUGALERT### What does this actually test?????
    if ($info->mode() & 022) { # Someone else can write this $fh.
        die <<EOD
App-Fetchware-Util: The file fetchware attempted to open [$file_to_check] is
writable by someone other than just the owner. Fetchwarefiles and fetchware
packages must only be writable by the owner. Do not only change permissions to
fix this error. This error may have allowed someone to alter the contents of
your Fetchwarefile or fetchware packages. Ensure the file was not altered, then
change permissions to 644.
EOD
    }
    
    # Then check the directories its contained in.

    # Make the file an absolute path if its not already.
    $file_to_check = rel2abs($file_to_check);

    # Create array of current directory and all parent directories and even root
    # directory to check all of their permissions below.
    my $dir = dir($file_to_check);
    my @directories = do {
        my @dirs;
        until ($dir eq rootdir()) {
            # Add this dir to the array of dirs to keep.
            push @dirs, $dir;

            # This loops version of $i++ the itcremeter.
            $dir = $dir->parent();
        }
        push @dirs, $dir->parent(); # $dir->parent() should be the root dir.

        # Return, by being the last statement, the list of parent dirs for
        # $file_to_check.
        @dirs;
    };
    # Who cares if _PC_CHOWN_RESTRICTED is set, check all parent dirs anyway,
    # because if say /home was 777, then anyone (other) can change any child
    # file in any directory above /home now anyway even if _PC_CHOWN_RESTRICTED
    # is set.
    for my $dir (@directories) {

        my $info = stat($dir);# or goto STAT_ERROR;

        # Owner must be either me (whoever runs fetchware) or superuser. No one
        # else can be trusted.
        if(($info->uid() != 0) && ($info->uid() != $<)) {
            die <<EOD;
App-Fetchware-Util: The file fetchware attempted to open is not owned by root or
the person who ran fetchware. This means the file could have been dangerously
altered, or it's a simple permissions problem. Do not simly change the
ownership, and rerun fetchware. Please check that the file [$file_to_check] has
not been tampered with, correct the ownership problems and try again.
EOD
        }

        # Check if group and other can write $fh.
        # Use 066 to detect read or write perms.
        ###BUGALERT### What does this actually test?????
        if ($info->mode() & 022) { # Someone else can write this $fh...
            # ...except if this file has the sticky bit set and its a directory.
            die <<EOD unless $info->mode & 01000 and S_ISDIR($info->mode);
App-Fetchware-Util: The file fetchware attempted to open [$file_to_check] is
writable by someone other than just the owner. Fetchwarefiles and fetchware
packages must only be writable by the owner. Do not only change permissions to
fix this error. This error may have allowed someone to alter the contents of
your Fetchwarefile or fetchware packages. Ensure the file was not altered, then
change permissions to 644. Permissions on failed directory were:
@{[Dumper($info)]}
Umask [@{[umask]}].
EOD
        }

    }
    # Return the proven above "safe" file handle.
    return $fh;

    # Use cool C style goto error handling. It beats copy and paste, and the
    # horrible contortions needed for "structured programming."
    STAT_ERROR: {
    die <<EOD;
App-Fetchware-Util: stat($fh) filename [$file_to_check] failed! This just
shouldn't happen unless of course the file you specified does not exist. Please
ensure files you specify when you run fetchware actually exist.
EOD
    }
}



sub drop_privs {
    my $child_code = shift;
    my $regular_user = shift // 'nobody';
    my %opts = @_;

    # Need to do this in 2 places.
    my $dont_drop_privs = sub {
        my $child_code = shift;

        my $output;
        open my $output_fh, '>', \$output or die <<EOD;
App-Fetchware-Util: fetchware failed to open an internal scalar reference as a
file handle. OS error [$!].
EOD
        $child_code->($output_fh);

        close $output_fh or die <<EOD;
App-Fetchware-Util: fetchware failed to close an internal scalar reference that
was open as a file handle. OS error [$!].
EOD
        return \$output;
    };

    # Execute $child_code without dropping privs if the user's configuration
    # file is configured to force fetchware to "stay_root."
    if (config('stay_root')) {
        msg <<EOM;
stay_root is set to true. NOT dropping privileges!
EOM
        return $dont_drop_privs->($child_code);
    }

    if (is_os_type('Unix') and ($< == 0 or $> == 0)) {
        # cmd_new() needs to skip the creation of this useless directory that it
        # does not use. Furthemore, the creation of this extra tempdir is not
        # needed by cmd_new(), and this tempdir presumes start() was called
        # before drop_privs(), which is always the case except for cmd_new().
        #
        # But another case where this temp dir's creations should be skipped is
        # if start() is overridden with hook() to make start() do something
        # other than create a temp dir, because in some cases such as using VCS
        # instead of Web sites and mirrors, you do not need to bother with
        # creating a tempdir, because the working dir of the repo can be used
        # instead. Therefore, if the parent directory is not /^fetchware-$$/,
        # then we'll also skip creating the tempd dir, because it most likely
        # means that a tempdir is not needed.
        $opts{SkipTempDirCreation} = 1
            unless file(cwd())->basename() =~  /^fetchware-$$/;
        unless (exists $opts{SkipTempDirCreation}
            and defined $opts{SkipTempDirCreation}
            and $opts{SkipTempDirCreation}) {
            # Ensure that $user_temp_dir can be accessed by my drop priv'd child.
            # And only try to change perms to 0755 only if perms are not 0755
            # already.
            my $st = stat(cwd());
            unless ((S_IMODE($st->mode) & 0755) >= 0755) {
                chmod 0755, cwd() or die <<EOD;
App-Fetchware-Util: Fetchware failed to change the permissions of the current
temporary directory [@{[cwd()]} to 0755. The OS error was [$!].
EOD
            }
            # Create a new tempdir for the droped prive user to use, and be sure
            # to chown it so they can actually write to it as well.
            # $new_temp_dir does not have a semaphore file, but its parent
            # directory does, which will still keep fetchware clean from
            # deleting this directory out from underneath us.
            #
            # Also note, that cwd() is "blindly" coded here, which makes it a
            # "dependency," but drop_privs() is meant to be called after start()
            # by fetchware::cmd_*(). It's not meant to be a generic subroutine
            # to drop privs, and it's also not really meant to be used by
            # fetchware extensions mostly just fetchware itself. Perhaps I
            # should move it back to bin/fetchware???
            my $new_temp_dir = tempdir("fetchware-$$-XXXXXXXXXX",
                DIR => cwd(), CLEANUP => 1);
            # Determine /etc/passwd entry for the "effective" uid of the
            # current fetchware process. I should use the "effective" uid
            # instead of the "real" uid, because effective uid is used to
            # determine what each uid can do, and the real uid is only
            # really used to track who the original user was in a setuid
            # program.
            my ($name, $useless, $uid, $gid, $quota, $comment, $gcos, $dir,
                $shell, $expire)
                = getpwnam(config('user') // 'nobody');
            chown($uid, $gid, $new_temp_dir) or die <<EOD;
App-Fetchware-Util: Fetchware failed to chown [$new_temp_dir] to the user it is
dropping privileges to. This just shouldn't happen, and might be a bug, or
perhaps your system temporary directory is full. The OS error was [$!].
EOD
            chmod(0700, $new_temp_dir) or die <<EOD;
App-Fetchware-Util: Fetchware failed to change the permissions of its new
temporary directory [$new_temp_dir] to 0700 that it created, because its
dropping privileges.  This just shouldn't happen, and is bug, or perhaps your
system temporary directory is full. The OS error is [$!].
EOD
            # And of course chdir() to $new_temp_dir, because everything assumes
            # that the cwd() is where everything should be saved and done.
            chdir($new_temp_dir) or die <<EOD;
App-Fetchware-Util: Fetchware failed to chdir() to its new temporary directory
[$new_temp_dir]. This shouldn't happen, and is most likely a bug, or perhaps
your system temporary directory is full. The OS error was [$!].
EOD
        }

        # Open a pipe to allow the child to talk back to the parent.
        pipe(READONLY, WRITEONLY) or die <<EOD;
App-Fetchware-Util: Fetchware failed to create a pipe to allow the forked
process to communication back to the parent process. OS error [$!].
EOD
        # Turn them into proper lexical file handles.
        my ($readonly, $writeonly) = (*READONLY, *WRITEONLY);

        # Set up a SIGPIPE handler in case the writer closes the pipe before the
        # reader closes their pipe.
        $SIG{'PIPE'} = sub {
            die <<EOD;
App-Fetchware-Util: Fetchware received a PIPE signal from the OS indicating the
pipe is dead. This should not happen, and is because the child was killed out
from under the parent, or there is a bug. This is a fatal error, because it's
possible the parent needs whatever information the child was going to use the
pipe to send to the parent, and now it is unclear if the proper expected output
has been received or not; therefore, we're just playing it safe and die()ing.
EOD
        };
        
        # Code below based on a cool forking idiom by Aristotle.
        # (http://blogs.perl.org/users/aristotle/2012/10/concise-fork-idiom.html)
        for ( scalar fork ) {
            # Fork failed.
            # defined() operates on default variable, $_.
            #if (not defined $_) {
            if ($_ eq undef) {
                die <<EOD;
App-Fetchware-Util: Fork failed! This shouldn't happen!?! Os error [$!].
EOD
            }

            # Fork succeeded, Parent code goes here.
            my $kidpid = $_;
            if ( $kidpid ) {
                close $writeonly or die <<EOD;
App-Fetchware-Util: Failed to close $writeonly pipe in parent. Os error [$!].
EOD
                my $output;

                # Read the child's output until child closes pipe sending EOF.
                $output .= $_ while (<$readonly>);

                # Close $readonly pipe, because we have received the output from
                # the user.
                close $readonly or die <<EOD;
App-Fetchware-Util: Failed to close $readonly pipe in parent. Os error [$!].
EOD

                # Just block waiting for the child to finish.
                waitpid($kidpid, 0);

                # If the child failed ($? >> 8 != 0), then the parent should
                # fail as well, because the child only exists to drop privs with
                # the ability to still at a later time execute something as root
                # again, so the fork is needed, because once you drop privs
                # you can't get them back, and you don't want to be able to for
                # security reasons.
                if (($? >> 8) != 0) {
                    # Note this message is only vmsg()'d instead of die()'d,
                    # because if its printed always, it could confuse users.
                    # Because priv_drop()ing is the default, this error would be
                    # seen all the time making getting confused by it likely.
                    vmsg <<EOD;
App-Fetchware-Util: An error occured forcing fetchware to exit while fetchware
has forked to drop its root priviledges to avoid downloading files and building
programs as root. Root priviledges are only maintained to install the software
in a system directory requiring root access. This error should have been
previously printed out by fetchware's lower priviledged child process above.
EOD
                    # Exit non-zero indicating failure, because whatever the
                    # child did failed, and the child's main eval {} in
                    # bin/fetchware caught that failure, printed it to the
                    # screen, and exit()ed non-zero for failure. And since the
                    # child failed ($? >> 8 != 0), the parent should fail too.
                    exit 1;
                # If successful, return to the child a ref of @output to caller.
                } else {
                    return \$output;
                }
            # Fork succeeded, child code goes here.
            } else {
                close $readonly or die <<EOD;
App-Fetchware-Util: Failed to close $readonly pipe in child. Os error [$!].
EOD
                # Drop privs.
                # drop_privileges() dies on an error just let drop_privs() caller
                # catch it.
                my ($uid, $gid) = drop_privileges($regular_user); 


                # Execute the coderef that is supposed to be done as non-root.
                $child_code->($writeonly);

                # Now close the pipe, to avoid creating a dead pipe causing a
                # SIGPIPE to be sent to the parent.
                close $writeonly or die <<EOD;
App-Fetchware-Util: Failed to close $writeonly pipe in child. Os error [$!].
EOD

                # Exit success, because failure is only indicated by a thrown
                # exception that bin/fetchware's main eval {} will catch, print,
                # and exit non-zero indicating failure.
                # Use POSIX's _exit() to avoid calling END{} blocks. This *must*
                # be done to prevent File::Temp's END{} block from attempting to
                # delete the temp directory that the parent still needs to
                # finish installing or uninstalling. The parent's END{} block's
                # will still be called, so this just turns off the child
                # deleting the temp dir not the parent.
                _exit 0;
            }
        }    
    # Non-Unix OSes just execute the $child_code.
    } else {
        return $dont_drop_privs->($child_code);
    }
}




###BUGALERT### Add quotemeta() support to pipe parsers to help prevent attacks.



{ # Bareblock just for the $MAGIC_NUMBER.
    # Determine $front_magic
    my $front_magic;
    $front_magic = int(rand(8128389023));
    # For no particular reason convert the random integer into hex, because I
    # never  store something in decimal and then exact same thing in hex.
    $front_magic = $front_magic . sprintf("%x", $front_magic);
    # Run srand() again to change random number generator between rand() calls.
    # Not really necessary, but should make it harder to guess correct magic
    # numbers.
    srand(time());
    # Same a $front_magic.
    my $back_magic = int(rand(986487516));
    # Octal this time :) for no real reason.
    $back_magic = $back_magic . sprintf("%o", $back_magic);
    my $MAGIC_NUMBER = $front_magic 
        . 'MAGIC_NUMBER_REPLACING_NEWLINE'
        . $back_magic;

sub write_dropprivs_pipe {
    my $write_pipe = shift;

    for my $a_var (@_) {
        die <<EOD if $a_var =~ /$MAGIC_NUMBER/;
fetchware: Huh? [$a_var] has fetchware's MAGIC_NUMBER in it? This shouldn't
happen, and messes up fetchware's simple IPC. You should never see this error,
because it's not a particuarly magic number if anybody actually uses it. This is
most likely a bug, so please report it.
EOD

        # Write to the $write_pipe, but use the $MAGIC_NUMBER instead of just
        # newline.
        print $write_pipe $a_var . $MAGIC_NUMBER;
    }
}



sub read_dropprivs_pipe {
    my $output = shift;

    die <<EOD if ref($output) ne 'SCALAR';
App-Fetchware-Util: pipe_read_newling() was called with an output variable
[$output] that was not a scalar reference. It must be a scalar reference.
EOD

    my @variables;
    for my $variable (split(/$MAGIC_NUMBER/, $$output)) {
        # And some error handling just in case.
        die <<EOD if not defined $variable;
fetchware: Huh? The child failed to write the proper variable back to the
parent! The variable is [$variable]. This should be defined but it is 
not!
EOD
        # Clear possibly tainted variables. It's a weird bug that makes no
        # sense. I don't turn -t or -T on, so what gives??? If you're curious
        # try commenting out the taint clearing code below, and running the
        # t/bin-fetchware-install.t test file (Or any other ones that call
        # drop_privs().).
        my $untainted;
        # Need the m//ms options to match strings with newlines in them.
        if ($variable =~ /(.*)/ms) {
            $untainted = $1;
        } else {
            die <<EOD;
App::Fetchware::Util: Untaint failed! Huh! This just shouldn't happen! It's
probably a bug. 
EOD
        }

        # Push $untainted instead of just $variable, because I want to return
        # untatined data instead of potentially tainted data.
        push @variables, $untainted;
    }

    return @variables;
}
###BUGALERT### Add some pipe parsers that use Storable too.

} # End $MAGIC_NUMBER bare block.







sub do_nothing {
    return;
}






{ # Begin scope block for $original_cwd.

    # $original_cwd is a scalar variable that stores fetchware's original
    # working directory for later use if its needed. It is access with
    # original_cwd() below.
    my $original_cwd;
    # $fh_sem is a semaphore lock file that create_tempdir() creates, and
    # cleanup_tempdir() closes clearing the lock. This is used to support
    # fetchware clean. The filehandle needs to be declared outside
    # create_tempdir()'s scope, because when this filehandle goes out of scope
    # the file is closed, and the lock is released, but fetchware needs to keep
    # hold of this lock for the life of fetchware to ensure that any fetchware
    # clean won't delete this fetchware temporary directory.
    my $fh_sem;


sub create_tempdir {
    my %opts = @_;

    msg 'Creating temp dir to use to install your package.';

    # Ask for better security.
    File::Temp->safe_level( File::Temp::HIGH );

    # Create the temp dir in the portable locations as returned by
    # File::Spec->tempdir() using the specified template (the weird $$ is this
    # processes process id), and cleaning up at program exit.
    my $exception;
    my $temp_dir;
    eval {
        local $@;

        # Determine tempdir()'s arguments.
        my @args = ("fetchware-$$-XXXXXXXXXX");#, TMPDIR => 1);

        # Specify the caller's TempDir (DIR) if they specify it.
        push @args, DIR => $opts{TempDir} if defined $opts{TempDir};

        # Specify either system temp directory or user specified directory.
        push @args,
            (defined $opts{TempDir} ? (DIR => $opts{TempDir}) : (TMPDIR => 1));

        # Don't CLEANUP if KeepTempDir is set.
        push @args, CLEANUP => 1 if not defined $opts{KeepTempDir};

        # Call tempdir() with the @args I've built.
        $temp_dir = tempdir(@args);

        # Only when we do *not* drop privs...
        if (config('stay_root')
                or ($< != 0 or $> != 0)
        ) {
            # ...Must chmod 700 so gpg's localized keyfiles are good.
            chmod(0700, $temp_dir) or die <<EOD;
App-Fetchware-Util: Fetchware failed to change the permissions of its temporary
directory [$temp_dir] to 0700. This should not happen, and is a bug, or perhaps
your system's temporary directory is full. The OS error was [$!].
EOD
        }

        $exception = $@;
        1; # return true unless an exception is thrown.
    } or die <<EOD;
App-Fetchware: run-time error. Fetchware tried to use File::Temp's tempdir()
subroutine to create a temporary file, but tempdir() threw an exception. That
exception was [$exception]. See perldoc App::Fetchware.
EOD

    $original_cwd = cwd();
    vmsg "Saving original working directory as [$original_cwd]";

    # Change directory to $CONFIG{TempDir} to make unarchiving and building happen
    # in a temporary directory, and to allow for multiple concurrent fetchware
    # runs at the same time.
    chdir $temp_dir or die <<EOD;
App-Fetchware: run-time error. Fetchware failed to change its directory to the
temporary directory that it successfully created. This just shouldn't happen,
and is weird, and may be a bug. See perldoc App::Fetchware.
EOD
    vmsg "Successfully changed working directory to [$temp_dir].";

    # Create 'fetcwhare.sem' - the fetchware semaphore lock file.
    open $fh_sem, '>', 'fetchware.sem' or die <<EOD;
App-Fetchware-Util: Failed to create [fetchware.sem] semaphore lock file! This
should not happen, because fetchware is creating this file in a brand new
directory that only fetchware should be accessing. You simply shouldn't see this
error unless some one is messing with fetchware, or perphaps there actually is a
bug? I don't know, but this just shouldn't happen. It's so hard to trigger it to
happen, it can't easily be tested in fetchware's test suite. OS error [$!].
EOD
    vmsg "Successfully created [fetchware.sem] semaphore lock file.";
    # Now flock 'fetchware.sem.' This should
    # Use LOCK_NB so flock won't stupidly wait forever and ever until the lock
    # becomes available.
    flock $fh_sem, LOCK_EX | LOCK_NB or die <<EOD;
App-Fetchware-Util: Failed to flock [fetchware.sem] semaphore lock file! This
should not happen, because this is being done in a brand new temporary directory
that only this instance of fetchware cares about. This just shouldn't happen. OS
error [$!].
EOD
    vmsg "Successfully locked [fetchware.sem] semaphore lock file using flock.";

    msg "Temporary directory created [$temp_dir]";

    return $temp_dir;
}



    sub original_cwd {
        return $original_cwd;
    }



sub cleanup_tempdir {
    msg 'Cleaning up temporary directory temporary directory.';

    # Close and unlock the fetchware semaphore lock file, 'fetchware.sem.'
    if (defined $fh_sem) {
        close $fh_sem or die <<EOD;
App-Fetchware-Util: Huh? close() failed! Fetchware failed to close(\$fh_sem).
Perhaps some one or something deleted it under us? Maybe a fetchware clean was
run with the force flag (--force) while this other fetchware was running?
OS error [$!].
EOD
        vmsg <<EOM;
Closed [fetchware.sem] filehandle to unlock this fetchware temporary directory from any
fetchware clean runs.
EOM
    }

    # chdir to original_cwd() directory, so File::Temp can delete the tempdir.
    # This is necessary, because operating systems do not allow you to delete a
    # directory that a running program has as its cwd.
    if (defined(original_cwd())) {
        vmsg "Changing directory to [@{[original_cwd()]}].";
        chdir(original_cwd()) or die <<EOD;
App-Fetchware: run-time error. Fetchware failed to chdir() to
[@{[original_cwd()]}]. See perldoc App::Fetchware.
EOD
    }

    # cleanup_tempdir() used to actually delete the temporary directory by using
    # File::Temp's cleanup() subroutine, but that subroutine deletes *all*
    # temporary directories that File::Temp has created and marked for deletion,
    # which might include directories created before this call to
    # cleanup_tempdir(), but are needed after. Therefore, cleanup_tempdir() no
    # longer actually deletes anything; instead, File::Temp can do it in its END
    # handler.
    #
    # The code below is left here on purpose, to remind everyone *not* to call
    # File::Temp's cleanup() here!! Do not do it!
    ###DONOTDO#### Call File::Temp's cleanup subrouttine to delete fetchware's temp
    ###DONOTDO#### directory.
    ###DONOTDO###vmsg 'Cleaning up temporary directory.';
    ###DONOTDO###File::Temp::cleanup();

    vmsg "Leaving tempdir alone. File::Temp's END handler will delete it.";

    vmsg 'Clearing internal %CONFIG variable that hold your parsed Fetchwarefile.';
    __clear_CONFIG();

    msg 'Cleaned up temporary directory.';

    # Return true.
    return 'Cleaned up tempdir';
}


} # End scope block for $original_cwd and $fh_sem.

1;

=pod

=head1 NAME

App::Fetchware::Util - Miscelaneous functions for App::Fetchware.

=head1 VERSION

version 1.002

=head1 SYNOPSIS

    use App::Fetchware::Util ':UTIL';


    # Logging subroutines.
    msg 'message to print to STDOUT';

    vmsg 'message to print to STDOUT';


    # Run external command subroutine.
    run_prog($program, @args);


    # Download subroutines.
    my $dir_list = download_dirlist($ftp_or_http_url)

    my $dir_list = ftp_download_dirlist($ftp_url);

    my $dir_list = http_download_dirlist($http_url);


    my $filename = download_file($url)

    my $filename = download_ftp_url($url);

    my $filename = download_http_url($url);

    my $filename = download_file_url($url);


    # Miscelaneous subroutines.
    just_filename()

    do_nothing();


    # Temporary directory subroutines.
    my $temp_dir = create_tempdir();

    my $original_cwd = original_cwd();

    cleanup_tempdir();

=head1 DESCRIPTION

App::Fetchware::Util holds miscelaneous utilities that fetchware needs for
various purposes such as logging and controling executed processes based on -q
or -v switches (msg(), vmsg(), run_prog()), subroutines for downloading
directory listings (*_dirlist()) or files (download_*()) using ftp, http, or
local files (file://), do_nothing() for extensions to fetchware, and subroutines
for managing a temporary directory.

=head1 LOGGING SUBROUTINES

These subroutines' log messages generated by fetchware by printing them to
C<STDOUT>. They do not currently support logging to a file directly, but you
could redirect fetchware's standard output to a file using your shell if you
want to:

    fetchware <some fetchware command> any arguments > fetchware.log
    fetchware upgrade-all > fetchware.log

=head2 Standards for using msg() and vmsg()

msg() should be used to describe the main events that happen, while vmsg()
should be used to describe what all of the main subroutine calls do.

For example, cmd_uninstall() has a msg() at the beginning and at the end, and so
do the main App::Fetchware subroutines that it uses such as start(), download(),
unarchive(), end() and so on. They both use vmsg() to add more detailed messages
about the particular even "internal" things they do.

msg() and vmsg() are also used without parens due to their appropriate
prototypes. This makes them stand out from regular old subroutine calls more.

=head2 msg()

    msg 'message to print to STDOUT' ;
    msg('message to print to STDOUT');

msg() simply takes a list of scalars, and it prints them to STDOUT according to
any verbose (-v), or quiet (-q) options that the user may have provided to
fetchware.

msg() will still print its arguments if the user provided a -v (verbose)
argument, but it will B<not> print its argument if the user provided a -q (quiet)
command line option.

=over 
=item This subroutine makes use of prototypes, so that you can avoid using parentheses around its args to make it stand out more in code.

=back

=head2 vmsg()

    vmsg 'message to print to STDOUT' ;
    vmsg('message to print to STDOUT');

vmsg() simply takes a list of scalars, and it prints them to STDOUT according to
any verbose (-v), or quiet (-q) options that the user may have provided to
fetchware.

vmsg() will B<only> print its arguments if the user provided a -v (verbose)
argument, but it will B<not> print its argument if the user provided a -q (quiet)
command line option.

=over 
=item This subroutine makes use of prototypes, so that you can avoid using parentheses around its args to make it stand out more in code.

=back

=head1 EXTERNAL COMMAND SUBROUTINES

run_prog() should be the B<only> function you use to execute external commands
when you L<extend your Fetchwarefile>, or L<write a fetchware extension>,
because run_prog() properly checks if the user specified the quiet switch
(C<-q>), and disables external commands from printing to C<STDOUT> if it has
been enabled.

=head2 run_prog()

    run_prog($program, @args);

    # Or let run_prog() deal with splitting the $command into multiple pieces.
    run_prig($command);

run_prog() uses L<system> to execute the program for you. Only the secure way of
avoiding the shell is used, so you can not use any shell redirection or any
shell builtins.

If the user ran fetchware with -v (verbose) then run_prog() changes none of its
behavior it still just executes the program. However, if the user runs the
program with -q (quiet) specified, then the the command is run using a piped
open to capture the output of the program. This captured output is then ignored,
because the user asked to never be bothered with the output. This piped open
uses the safer shell avoiding syntax on systems with L<fork>, and systems
without L<fork>, Windows,  the older less safe syntax is used. Backticks are
avoided, because they always use the shell.

run_prog() when called with only one argument will split that one argument into
multiple pieces using L<Text::ParseWords> quotewords() subroutine, which
properly deals with quotes just like the shell does. quotewords() is always used
even if you provide an already split up list of arguments to run_prog().

=head2 Executing external commands without using run_prog()

Subify the -q checking code, and paste it below, and tell users to use that if
they want to use something else, and document the $fetchware::quiet variable for
other users too.

msg(), vmsg(), and run_prog() determine if -v and if -q were specified by
checking the values of the global variables listed below:

=over

=item * $fetchware::quiet - is C<0> if -q was B<not> specified.
=item * $fetchware::verbose - is C<0> if -v was B<not> specified.

=back

Both of these variables work the same way. If they are 0, then -q or -v was
B<not> specified. And if they are defined and greather than (>) 0, then -q or -v
were specified on the command line. You should test for greater than 0 B<not>
B<== 1>, because Fetchware takes advantage of a cool feature in GetOpt::Long
allowing the user to specify -v and -q more than once. This triggers either
$fetchware::quiet or $fetchware::verbose to be greater than one, which would
cause a direct C<== 1> test to fail even though the user is no asking for
I<more> verbose messages. Internally Fetchware only supports on verbositly
level.

=head1 DOWNLOAD SUBROUTINES

App::Fetchware::Util's download_*() and *_dirlist() subroutines allow you to
download FTP, HTTP, or local file (file://) directory listings or files
respectively. 

=over 
=item NOTICE
Each  *_dirlist() subroutine returns its own format that is different from the
others. Fetchware uses the *_parse_filelist() subroutines to parse this
differing directory listings into a specifc format of an array of arrays of
filenames and timestamps. You could load these subroutines from the
C<OVERRIDE_LOOKUP> App::Fetchware export tag to use in your Fetchwarefile or
your fetchware extension.

=back

=head2 download_dirlist()

    my $dir_list = download_dirlist($url)

    my $dir_list = download_dirlist(PATH => $path)

Can be called with either a $url or a PATH parameter. When called with a $url
parameter, the specified $url is downloaded using no_mirror_download_dirlist(),
and returned if successful. If it fails then each C<mirror> the user specified
is also tried unitl there are no more mirrors, and then an exception is thrown.

If you specify a PATH parameter instead of a $url parameter, then that path is
appended to each C<mirror>, and the resultant url is downloaded using
no_mirror_download_dirlist().

=head2 no_mirror_download_dirlist()

    my $dir_list = no_mirror_download_dirlist($ftp_or_http_url)

Downloads a ftp or http url and assumes that it will be downloading a directory
listing instead of an actual file. To download an actual file use
L<download_file()>. download_dirlist returns the directory listing that it
obtained from the ftp or http server. ftp server will be an arrayref of C<ls -l>
like output, while the http output will be a scalar of the HTML dirlisting
provided by the http server.

=head2 ftp_download_dirlist()

    my $dir_list = ftp_download_dirlist($ftp_url);

Uses Net::Ftp's dir() method to obtain a I<long> directory listing. lookup()
needs it in I<long> format, so that the timestamp algorithm has access to each
file's timestamp.

Returns an array ref of the directory listing.

=head2 http_download_dirlist()

    my $dir_list = http_download_dirlist($http_url);

Uses HTTP::Tiny to download a HTML directory listing from a HTTP Web server.

Returns an scalar of the HTML ladden directory listing.

If an even number of other options are specified (a faux hash), then those
options are forwarded on to L<HTTP::Tiny>'s new() method. See L<HTTP::Tiny> for
details about what these options are. For example, you couse use this to add a
C<Referrer> header to your request if a download site annoying checks referrers.

=head2 file_download_dirlist()

    my $file_listing = file_download_dirlist($local_lookup_url)

Glob's provided $local_lookup_url, and builds a directory listing of all files
in the provided directory. Then list_file_dirlist() returns a list of all of the
files in the current directory.

=head2 download_file()

    my $filename = download_file($url)

    my $filename = download_file(PATH => $path)

Can be called with either a $url or a PATH parameter. When called with a $url
parameter, the specified $url is downloaded using no_mirror_download_file(),
and returned if successful. If it fails then each C<mirror> the user specified
is also tried unitl there are no more mirrors, and then an exception is thrown.

If you specify a PATH parameter instead of a $url parameter, then that path is
appended to each C<mirror>, and the resultant url is downloaded using
no_mirror_download_file().

=head2 no_mirror_download_file()

    my $filename = no_mirror_download_file($url)

Downloads one $url and assumes it is a file that will be downloaded instead of a
file listing that will be returned. no_mirror_download_file() returns the file
name of the file it downloads.

Like its name says it does not try any configured mirrors at all. This
subroutine should not be used; instead download_file() should be used, because
you should respect your user's desired mirrors.

=head2 download_ftp_url()

    my $filename = download_ftp_url($url);

Uses Net::FTP to download the specified FTP URL using binary mode.

=head2 download_http_url()

    my $filename = download_http_url($url);

Uses HTTP::Tiny to download the specified HTTP URL.

Supports adding extra arguments to HTTP::Tiny's new() constructor. These
arguments are B<not> checked for correctness; instead, they are simply forwarded
to HTTP::Tiny, which does not check them for correctness either. HTTP::Tiny
simply loops over its internal listing of what is arguments should be, and then
accesses the arguments if they exist.

This was really only implemented to allow App::FetchwareX::HTMLPageSync to change
its user agent string to avoid being blocked or freaking out Web developers that
they're being screen scraped by some obnoxious bot as HTMLPageSync is wimpy and
harmless, and only downloads one page. 

You would add an argument like this:
download_http_url($http_url, agent => 'Firefox');

See HTTP::Tiny's documentation for what these options are.

=head2 download_file_url()

    my $filename = download_file_url($url);

Uses File::Copy to copy ("download") the local file to the current working
directory.

=head1 TEMPDIR SUBROUTINES

These subroutines manage the creation of a temporary directory for you. They
also implement the original_cwd() getter subroutine that returns the current
working directory fetchware was at before create_tempdir() chdir()'d to the
temporary directory you specify. File::Temp's tempdir() is used, and
cleanup_tempdir() manages the C<fetchware.sem> fetchware semaphore file.

=over 
=item NOTICE
App::Fetchware::Util's temporary directory creation utilities, create_tempdir(),
original_cwd(), and cleanup_tempdir(), only keep track of one tempdir at a time. If
you create another tempdir with create_tempdir() it will override the value of
original_cwd(), which may mess up other functions that call create_tempdir(),
original_cwd(), and cleanup_tempdir(). Therefore, becareful when you call these
functions, and do B<not> use them inside a fetchware extension if you reuse
App::Fetchware's start() and end(), because App::Fetchware's start() and end()
use these functions, so your use of them will conflict. If you still need to
create a tempdir just call File::Temp's tempdir() directly.

=back

=head2 create_tempdir()

    my $temp_dir = create_tempdir();

Creates a temporary directory, chmod 700's it, and chdir()'s into it.

Accepts the fake hash argument C<KeepTempDir => 1>, which tells create_tempdir()
to B<not> delete the temporary directory when the program exits.

Also, accepts C<TempDir =E<gt> '/tmp'> to specify what temporary directory to
use. The default with out this argument is to use tempdir()'s default, which is
whatever File::Spec's tmpdir() says to use.

The C<NoChown =E<gt> 1> option causes create_tempdir() to B<not> chown to
config('user').

=head3 Locking Fetchware's temp directories with a semaphore file.

In order to support C<fetchware clean>, create_tempdir() creates a semaphore
file. The file is used by C<fetchware clean> (via bin/fetchware's cmd_clean())
to determine if another fetchware process out there is currently using this
temporary directory, and if it is not, the file is not currently locked with
flock, then the entire directory is deleted using File::Path's remove_path()
function. If the file is there and locked, then the directory is skipped by
cmd_clean(). Note: you can call C<fetchware clean> with the -f or --force option
to force fetchware to delete B<all> fetchware temporary directories even out
from under the pants of any currently running fetchware process!

cleanup_tempdir() is responsible for unlocking the semaphore file that
create_tempdir() creates. However, the coolest part of using flock is that if
fetchware is killed in any manner whether its C<END> block or File::Temp's
C<END>block run, the OS will still unlock the file, so no edge cases need
handling, because the OS will do them for us!

=head2 original_cwd()

    my $original_cwd = original_cwd();

original_cwd() simply returns the value of fetchware's $original_cwd that is
saved inside each create_tempdir() call. A new call to create_tempdir() will
reset this value. Note: App::Fetchware's start() also calls create_tempdir(), so
another call to start() will also reset original_cwd().

=head2 cleanup_tempdir()

    cleanup_tempdir();

Cleans up B<any> temporary files or directories that anything in this process used
File::Temp to create. You cannot only clean up one directory or another;
instead, you must just use this sparingly or in an END block although file::Temp
takes care of that for you unless you asked it not to.

It also closes $fh_sem, which is the filehandle of the 'fetchware.sem' file
create_tempdir() opens and I<locks>. By closing it in cleanup_tempdir(), we're
unlocking it. According to MJD's "File Locking Tips and Traps," it's better to
just close the file, then use flock to unlock it.

=head1 SECURITY SUBROUTINES

This section describes Utilty subroutines that can be used for checking security
of files on the file system to see if fetchware should open and use them.

=head2 safe_open()

    my $fh = safe_open($file_to_check, <<EOE);
    App-Fetchware-Extension???: Failed to open file [$file_to_check]! Because of
    OS error [$!].
    EOE

    # To open for writing instead of reading 
    my $fh = safe_open($file_to_check, <<EOE, MODE => '>');
    App-Fetchware-Extension???: Failed to open file [$file_to_check]! Because of
    OS error [$!].
    EOE

safe_open() takes $file_to_check and does a bunch of file checks on that
file to determine if it's safe to open and use the contents of that file in
your program. Instead of returning true or false, it returns a file handle of
the file you want to check that has already been open for you. This is done to
prevent race conditions between the time safe_open() checks the file's safety
and the time the caller actually opens the file.

safe_open() also takes an optional second argument that specifies a caller
specific error message that replaces the generic default one.

Fetchware occasionally needs to write files especially in fetchware's new()
command; therefore safe_open() also takes the fake hash argument
C<MODE =E<gt> 'E<gt>'>, which opens the file in a mode specified by the caller.
C<'E<gt>'> is for writing for example. See C<perldoc -f open> for a list of
possible modes.

In fetchware, this subroutine is used to check if every file fetchware
opens is safe to do so. It is based on is_safe() and is_very_safe() from the
Perl Cookbook by Tom Christiansen and Nathan Torkington.

What this subroutine checks:

=over

=item *

It opens the file you give to it as an argument, and all subsequent operations
are done on the opened filehandle to prevent race conditions.

=item *

Then it checks that the owner of the specified file must be either the superuser
or the user who ran fetchware.

=item *

It checks that the mode, as returned by File::stat's overridden stat, is not
writable by group or other. Fancy MAC permissions such as Linux's extfs's
extensions and fancy Windows permissions are B<not> currently checked.

=item *

Then safe_open() stat's each and every parent directory that is in this file's
full path, and runs the same checks that are run above on each parent directory.

=item *

_PC_CHOWN_RESTRICTED is not tested; instead what is_very_safe() does is simply
always done. Because even with A _PC_CHOWN_RESTRICTED test, /home, for example,
could be 777. This is Unix after all, and root can do anything including screw
up permissions on system directories.

=back

If you actually are some sort of security expert, please feel free to
double-check if the list of stuff to check for is complete, and perhaps even the
Perl implementation to see if the subroutien really does check if
safe_open($file_to_check) is actually safe.

=over

=item WARNING

According to L<perlport>'s chmod() documentation, on Win32 perl's Unixish file
permissions arn't supported only "owner" is:

"Only good for changing "owner" read-write access, "group", and "other" bits are
meaningless. (Win32)"

I'm not completely sure this means that under Win32 only owner perms mean
something, or if just chmod()ing group or ther bits don't do anything, but
testing if group and other are rwx does work. This needs testing.

And remember this only applies to Win32, and fetchware has not yet been properly
ported or tested under Win32 yet.

=back

=head2 drop_privs()

    my $output = drop_privs(sub {
        my $write_pipe = shift;
        # Do stuff as $regular_user
        ...
        # Use write_dropprivs_pipe to share variables back to parent.
        write_dropprivs_pipe($write_pipe, $var1, $var2, ...);

        }, $regular_user
    );

    # Back in the parent, use read_dropprivs_pipe() to read in whatever
    # variables the child shared with us.
    my ($var1, $var2, ...) = read_dropprivs_pipe($output);

Forks and drops privs to $regular_user, and then executes whatever is in the
first argument, which should be a code reference. Throws an exception on any
problems with the fork.

It only allows you to specify what the lower priveledged user does. The parent
process's behavior can not be changed. All the parent does:

=over

=item *

Create a pipe to allow the child to communicate any information back to the
parent.

=item *

Read any data the child may write to that pipe.

=item *

After the child has died, collect the child's exit status.

=item *

And return the output the child wrote on the pipe as a scalar reference.

=back

Whatever the child writes is returned. drop_privs() does not use Storable or
JSON or XML or anything. It is up to you to specify how the data is to be
represented and used. However, L<read_dropprivs_pipe()> and
L<write_dropprivs_pipe()> are provided.  They provide a simple way to store
multiple variables that can have any character in them including newline. See
their documentation for details.

=over

=item SECURITY NOTICE

The output returned by drop_privs() is whatever the child wants it to be. If
somehow the child got hacked, the $output could be something that could cause
the parent (which has root perms!) to execute some code, or otherwise do
something that could cause the child to gain root access. So be sure to check
how you use drop_privs() return value, and definitley don't just string eval it.
Structure it so the return value can only be used as data for variables, and
that those variables are never executed by root.

=back

drop_privs() handles being on nonunix for you. On a platform that is not Unix
that does not have Unix's fork() and exec() security model, drop_privs() simply
executes the provided code reference I<without> dropping priveledges.

=over

=item USABILITY NOTICE 

drop_privs()'s implementation depends on start() creating a tempdir and
chdir()ing to it. Furthermore, drop_privs() sometimes creates a tempdir of its
own, and it does not do a chdir back to another directory, so drop_privs()
depends on end() to chdir back to original_cwd(). Therefore, do not use
drop_privs() without also using start() and end() to manage a temporary
directory for drop_privs().

=back

drop_privs() also supports a C<SkipTempDirCreation =E<gt> 1> option that turns
off drop_privs() creating a temporary diretory to give the child a writable
temporary directory. This option is only used by cmd_new(), and probably only
really needs to be used there. Also, note that you must provide this option
after the $child_code coderef, and the $regular user options. Like so,
C<my $output = drop_privs($child_code, $regular_user, SkipTempDirCreation =E<gt> 1>.

=head2 drop_privs() PIPE PARSING UTILITIES

drop_privs() uses a pipe for IPC between the child and the parent. This section
contains utilties that help users of drop_privs() parse the input and output
they send from the child back to the parent.

Use write_dropprivs_pipe() to send data back to the parent, that later you'll read
with read_dropprivs_pipe() back in the parent.

=head3 write_dropprivs_pipe()

    write_dropprivs_pipe($write_pipe, $variable1, $variable2, $variable3);

Simply uses the caller provided $write_pipe file handle to write the rest of its
args to that file handle separated by a I<magic number>.

This magic number is just generated uniquely each time App::Fetchware::Util is
compiled. This number replaces using newline to separate each of the variables
that write_dropprivs_pipe() writes. This way you can include newline, and in
fact anything that does not contain the magic number, which is obviously
suitably unlikely.

=head3 read_dropprivs_pipe()

    my ($variable1, $variable2, $variable3) = pipe_read_newling($output);

read_dropprivs_pipe() opens the scalar $output, and returns a list of $outputs
parsed out variables split on the $MAGIC_NUMBER, which is randomly generated
during each time you run Fetchware to avoid you every actually using it.

=head1 MISCELANEOUS UTILTY SUBROUTINES

This is just a catch all category for everything else in App::Fetchware::Utility.

=head2 do_nothing()

    do_nothing();

do_nothing() does nothing but return. It simply returns doing nothing. It is
meant to be used by App::Fetchware "subclasses" that "override" App::Fetchware's
API subroutines to make those API subroutines do nothing.

=head1 ERRORS

As with the rest of App::Fetchware, App::Fetchware::Util does not return any
error codes; instead, all errors are die()'d if it's App::Fetchware::Util's
error, or croak()'d if its the caller's fault. These exceptions are simple
strings, and are listed in the L</DIAGNOSTICS> section below.

=head1 BUGS 

App::Fetchware::Util's temporary directory creation utilities, create_tempdir(),
original_cwd(), and cleanup_tempdir(), only keep track of one tempdir at a time. If
you create another tempdir with create_tempdir() it will override the value of
original_cwd(), which may mess up other functions that call create_tempdir(),
original_cwd(), and cleanup_tempdir(). Therefore, be careful when you call these
functions, and do B<not> use them inside a fetchware extension if you reuse
App::Fetchware's start() and end(), because App::Fetchware's start() and end()
use these functions, so your use of them will conflict. If you still need to
create a tempdir just call File::Temp's tempdir() directly.

=head1 AUTHOR

David Yingling <deeelwy@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by David Yingling.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

__END__






###BUGALERT### Actually implement croak or more likely confess() support!!!


##TODO##=head1 DIAGNOSTICS
##TODO##
##TODO##App::Fetchware throws many exceptions. These exceptions are not listed below,
##TODO##because I have not yet added additional information explaining them. This is
##TODO##because fetchware throws very verbose error messages that don't need extra
##TODO##explanation. This section is reserved for when I have to actually add further
##TODO##information regarding one of these exceptions.
##TODO##
##TODO##=cut


