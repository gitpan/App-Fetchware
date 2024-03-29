package App::Fetchware::ExportAPI;
$App::Fetchware::ExportAPI::VERSION = '1.014';
# ABSTRACT: Used by fetchware extensions to export their API subroutines.
use strict;
use warnings;

# CPAN modules making Fetchwarefile better.
use Sub::Mage;

# ExportAPI takes advantage of CreateConfigOption's _create_config_options() and
# _add_export() to do its dirty work.
use App::Fetchware::CreateConfigOptions ();
# _create_config_options() clone()'s some of App::Fetchware's API subroutines
# when a fetchware extension "KEEP"s them, so I must load it, so I can access
# these subroutines.
use App::Fetchware ();

# Enable Perl 6 knockoffs, and use 5.10.1, because smartmatching and other
# things in 5.10 were changed in 5.10.1+.
use 5.010001;

# Don't use Exporter's import; instead, provide your own. This is all ExportAPI
# does. Provide an import() method, so that it can set up correct exports, and
# ensure that your fetchware extension implementes all of fetchware's API
# subroutines at compile time.



sub import {
    my ($class, @opts) = @_;

    # Just return success if user specified no options, because that just means
    # the user wanted to load the module, but not actually import() anything.
    return 'Success' if @opts == 0;

    my $caller = caller;

    # Forward call to _export_api(), which does all the work.
    _export_api($caller, @opts);
}


# _export_api() has pretty much the same documentation as import() above, and
# why copy and paste any changes I make, when this not here makes more sense?
sub _export_api {
    my ($callers_package_name, %opts) = @_;

    # clone() Exporter's import() into $callers_package_name, because
    # fetchware extensions use Exporter's import() when fetchware eval()'s
    # Fetchwarefile's that use that extension. Exporter's import() is what makes
    # the magic happen.
    clone(import => (from => 'Exporter', to => $callers_package_name));

    my %api_subs = (
        check_syntax => 0,
        new => 0,
        new_install => 0,
        start => 0,
        lookup => 0,
        download => 0,
        verify => 0,
        unarchive => 0,
        build => 0,
        install => 0,
        end => 0,
        uninstall => 0,
        upgrade => 0,
    );

    # Check %opts for correctness.
    for my $sub_type (@opts{qw(KEEP OVERRIDE)}) {
        # Skip KEEP or OVERRIDE if it does not exist.
        # Needed, because the obove hash slice access will create it if it does
        # not already exist.
        next unless defined $sub_type;
        for my $sub (@{$sub_type}) {
            if (exists $api_subs{$sub}) {
                $api_subs{$sub}++;
            } 
        }
    }

    # Use (scalar keys %api_subs) to dynamically determine how many API subs
    # there are. I've implemented all of the ones that I've planned, but another
    # upgrade() or check_syntax() could come out of now where, so calculate how
    # many there are dynamically, and then I only have to remember to update
    # %api_subs; instead, of that and also incrementing a constant integer
    # that's now properly a constant.
    die <<EOD if (grep {$api_subs{$_} == 1} keys %api_subs) != (scalar keys %api_subs);
App-Fetchware-ExportAPI: _export_api() or import() must be called with either or
both of the KEEP and OVERRIDE options, and you must supply the names of all of
fetchware's API subroutines to either one of these 2 options.
EOD

    # Import any KEEP subs from App::Fetchware.
    for my $sub (@{$opts{KEEP}}) {
        clone($sub => ( from => 'App::Fetchware', to => $callers_package_name));

    }

    # Also import any subroutines the fetchware extension developer wants to
    # keep unless the fetchware extension developer does not want them.
    App::Fetchware::CreateConfigOptions::_create_config_options(
        $callers_package_name,
        IMPORT => $opts{KEEP})
            unless $opts{NOIMPORT};

    ###LIMITATION###You may want _export_api() and import() and ExportAPI to
    #check if all of the required fetchware extension API subroutines have been
    #implemented by our caller using something like
    #"$callers_package_name"->can($sub), but this can't work, because ExportAPI
    #is run inside an implied BEGIN block, from the use(), That means that the
    #rest of the file has *not* been compiled yet, so any subroutines defined
    #later on in the same file have not actually been compiled yet, so any use
    #of can() to lookup if they exist yet will fail, because they don't actually
    #exist yet. But if they have been properly defined, they will properly
    #exist.
    #
    #Therefore, I have moved checking if all of the proper API subroutines have
    #been defined properly to bin/fetchware's parse_fetchwarefile(), because
    #after the Fetchwarefile has been eval()'s the API subroutines should be in
    #bin/fetchware's namespace, so it just uses Sub::Mage's sublist() to see if
    #they all exist.


    # _create_config_options() takes care of setting up KEEP's exports, but
    # I need to ensure OVERRIDE's exports are also set up.
    App::Fetchware::CreateConfigOptions::_add_export(
        $_, $callers_package_name)
            for @{$opts{OVERRIDE}};
}


1;

__END__

=pod

=head1 NAME

App::Fetchware::ExportAPI - Used by fetchware extensions to export their API subroutines.

=head1 VERSION

version 1.014

=head1 SYNOPSIS

    use App::Fetchware::ExportAPI KEEP => [qw(start end new_install)],
        OVERRIDE =>
            [qw(new lookup download verify unarchive build install uninstall
            upgrade check_syntax)];

=head1 DESCRIPTION

App::Fetchware::ExportAPI is a utility helper class for fetchware extensions. It
makes it easy to ensure that your fetchware extension implements or imports all
of App::Fetchware's required API subroutines.

See section L<App::Fetchware/CREATING A FETCHWARE EXTENSION> in App::Fetchware's
documentation for more information on how to create your very own fetchware
extension.

=head1 EXPORTAPI'S API METHODS

App::Fetchware::ExportAPI (ExportAPI) has only one user-servicable part--it's
import() method. It works just like L<Exporter>'s import() method except it
takes arguments differently, and checks it's arguments more thoroughly.

It's import() method is what does the heavy lifting of actually importing any
"inherited" Fetchware API subroutines from App::Fetchware, and also setting up
the caller's exports, so that the caller also exports all of Fetchware's API
subroutines.

=head2 import()

    # You don't actually call import() unless you're doing something weird.
    # Instead, use calls import for you.
    use App::Fetchware::ExportAPI KEEP => [qw(start end)],
        OVERRIDE =>
            [qw(lookup download verify unarchive build install uninstall)];

    # But if you really do need to run import() itself.
    BEGIN {
        require App::Fetchware::ExportAPI;
        App::Fetchware::ExportAPI->import(KEEP => [qw(start end)],
            OVERRIDE =>
                [qw(lookup download verify unarchive build install uninstall)]
        );
    }

Adds fetchware's API subroutines (new(), new_install(), check_syntax(), start(),
lookup(), download(), verify(), unarchive(), build(), install(), end(),
uninstall(), and upgrade()) to the caller()'s  @EXPORT.  It also imports
L<Exporter>'s import() subroutine to the caller's package, so that the caller 
as a proper import() subroutine that Perl will use when someone uses your
fetchware extension in their fetchware extension. Used by fetchware extensions
to easily add fetchware's API subroutines to your extension's package exports.

The C<KEEP> type is how fetchware extensions I<inherit> whatever API subroutines that they
want to reuse from App::Fetchware, while C<OVERRIDE> specifies which API
subroutines this Fetchware extension will implement itself or "override".

Normally, you don't actually call import(); instead, you call it implicity by
simply use()ing it.

=over

=item NOTE

All API subroutines that exist in App::Fetchware's API must be mentioned in the
call to import (or implicitly via use). You do not have to OVERRIDE them all,
but those that you do not OVERRRIDE must be mentioned in KEEP. The KEEP tag does
not cause import() to actually do anything with them, but they nevertheless must
be mentioned. 

=back

=over

=item WARNING

_export_api() also imports Exporter's import() method into its
$callers_package_name. This is absolutely required, because when a user's
Fetchwarefile is parsed it is the C<use App::Fetchware::[extensionname];> line
that imports fetchware's API subrotines into fetchware's namespace so its
internals can call the correct fetchware extension. This mechanism simply uses
Exporter's import() method for the heavy lifting, so import() B<must> also
ensure that its caller gets a proper import() method.

If no import() method is in your fetchware extension, then fetchware will fail
to parse any Fetchwarefile's that use your fetchware extension, but this error
is caught with an appropriate error message.

=back

=head1 ERRORS

As with the rest of App::Fetchware, App::Fetchware::ExportAPI does not return 
any error codes; instead, all errors are die()'d if it's Test::Fetchware's error,
or croak()'d if its the caller's fault.

=head1 AUTHOR

David Yingling <deeelwy@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by David Yingling.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
