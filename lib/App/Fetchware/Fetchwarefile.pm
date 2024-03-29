package App::Fetchware::Fetchwarefile;
$App::Fetchware::Fetchwarefile::VERSION = '1.014';
# ABSTRACT: Helps Fetchware extensions create Fetchwarefiles.
###BUGALERT### Uses die instead of croak. croak is the preferred way of throwing
#exceptions in modules. croak says that the caller was the one who caused the
#error not the specific code that actually threw the error.
use strict;
use warnings;

# Enable Perl 6 knockoffs, and use 5.10.1, because smartmatching and other
# things in 5.10 were changed in 5.10.1+.
use 5.010001;

use Text::Wrap 'wrap';
use App::Fetchware::Util 'vmsg';
use Carp 'croak';



sub new {
    my ($class, %options) = @_;

    if (not exists $options{header}
        and not defined $options{header}) {
        croak <<EOC;
Fetchwarefile: you failed to include a header option in your call to
App::Fetchware::Fetchwarefile's new() constructor. Please add the required
header and try again.
EOC
    # Above tests if $options{header} does not exist and is not defined, so this
    # else means that it does indeed exist and is defined.
    } else {
        if ($options{header} !~ /^use\s+App::FetchwareX?/m) {
            die <<EOD;
Fetchwarefile: Your header does not have a App::Fetchware or App::FetchwareX::*
extension declaration. This line is manadatory, and Fetchware requires it,
because it needs it to load its or its extensions's configuration subroutines.
The erroneous header you provided is:
[
$options{header}
]
EOD
        }
    }
    if (not exists $options{descriptions}
        and not defined $options{descriptions}) {
        croak <<EOC;
Fetchwarefile: you failed to include a descriptions hash option in your call to
App::Fetchware::Fetchwarefile's new() constructor. Please add the required
header and try again.
EOC
    }
    if (ref $options{descriptions} ne 'HASH') {
        croak <<EOC;
Fetchwarefile: the descriptions hash value must be a hash ref whoose keys are
configuration options, and whoose values are descriptions to insert into the
generated Fetchwarefile when those options are added to your Fetchwarefile.
EOC
    }


    # Initialize order as instance data. This variable is used by generate() to
    # track the order as config options are added to the $fetchwarefile object.
    $options{order} = 1;

    return bless \%options, $class;
}



sub config_options {
    my $self = shift;

    # If only one option is provided, then config_options() is a getter, and
    # should return that one value back to the caller.

    if (@_ == 1) {
        # If the requested key is a arrayref deref it, and return it...
        if (ref $self->{config_options_value}->{$_[0]} eq 'ARRAY') {
            return @{$self->{config_options_value}->{$_[0]}};
        #...otherwise just return the one scalar.
        } else {
            return $self->{config_options_value}->{$_[0]};
        }
    # Otherwise config_options() is a setter, and should set the rest of its
    # objects (@_) as the
    } else {
        # Store the %options inside $self's under $self's config_options_value hash key,
        # and be sure to use an array to support 'MANY' and 'ARRREF' types.
        my %options = @_;

        for my $config_key (keys %options) {

            if (ref $self->{config_options_value}->{$config_key} eq 'ARRAY') {
                if (ref $options{$config_key} eq 'ARRAY') {
                    push @{$self->{config_options_value}->{$config_key}},
                        @{$options{$config_key}};
                } else {
                    push @{$self->{config_options_value}->{$config_key}},
                        $options{$config_key};
                }
            } else { 
                if (exists $self->{config_options_value}->{$config_key}
                        and
                    defined $self->{config_options_value}->{$config_key}
                        and
                    ref $self->{config_options_value}->{$config_key} eq ''
                ) {
                    if (ref $options{$config_key} eq 'ARRAY') {
                        push @{$self->{config_options_value}->{$config_key}},
                            # Prepend existing arrayref...
                            @{$self->{config_options_value}->{$config_key}},
                            # ...and the new array ref, but remember to deref it.
                            @{$options{$config_key}};
                    } else {
                        # Set the hash directly to the value, because if it has
                        # a scalar value, then it is not undef, and push will
                        # only autovivify the array ref if its undef; therefore,
                        # I must set the hash value to an array ref directly
                        # instead.
                        $self->{config_options_value}->{$config_key} =
                            [
                                # Prepend existing scalar...
                                $self->{config_options_value}->{$config_key},
                                # ...and the new scalar too.
                                $options{$config_key}
                            ];
                    }
                } else {
                    if (ref $options{$config_key} eq 'ARRAY') {
                        $self->{config_options_value}->{$config_key} = [
                            @{$options{$config_key}}
                        ];
                    } else {
                        $self->{config_options_value}->{$config_key} = $options{$config_key};
                    }
                }
            } 
        }

        # Store the order that this $config_key was stored in
        # config_options_value in it's parallel hash config_options_order...
        # Copied and pasted from code by brian d foy from Stack Overflow:
        # http://stackoverflow.com/questions/569772
        for (my $i = 0; $i < @_; $i += 2) {
            my ($option_name, $option_value) = @_[ $i, $i+1 ];

            $self->{config_options_order}->{$option_name} = $self->{order}++
                unless exists $self->{config_options_order}->{$option_name};
        }
    }
}




sub generate {
    my $self = shift;

    # Stores the Fetchwarefile that we're generating for our caller.
    my $fetchwarefile;

    # First add the header to the $fetchwarefile.
    $fetchwarefile .= $self->{header};

    # Add a newline or 2 if needed.
    unless ($fetchwarefile =~ /(\n)(\n)$/) {
        $fetchwarefile .= "\n" if defined($1) and $1 eq "\n";
        $fetchwarefile .= "\n" if defined($2) and $2 eq "\n";
    }

    # Ensure that $self->{config_options_values} and
    # $self->{config_options_order} parallel hashes have the same number of
    # keys.

    unless (
        keys %{$self->{config_options_value}}
            ==
        keys %{$self->{config_options_order}}
    ) {
        die <<EOD;
App-Fetchware-Fetchwarefile: your call to generate() failed, because the data
that generate() uses internally is somehow screwed up. This is probably a bug,
because App::Fetchware::Fetchwarefile's internals are not supposed to be messed
with except by itself of course.
EOD
    }

    # Tracks how many times each Fetchwarefile configuration option is used, so
    # that each options description is only put in the Fetchwarefile only once.
    my %description_seen;

    # Loop over all the keys that were added with config_options(), which are
    # stored in config_options_value, but use config_options_order to sort them,
    # which stores the order in which the first value was added for each like
    # key in config_options_value.
    for my $option_key (sort {
            $self->{config_options_order}->{$a}
            <=>
            $self->{config_options_order}->{$b}
        }
        keys %{$self->{config_options_value}}
    ) {
        # Due to Fetchwarefile storing each option as an array, and
        # config_option() returning that array, which may consist of only one
        # value, I need to loop through them just in case a 'MANY' or
        # 'ONEARRREF' type configuration option is used.
        for my $option_value ($self->config_options($option_key)) {
            if (defined $self->{descriptions}->{$option_key}) {
                # If the description has not been written to the $fetchwarefile yet,
                # then include it.
                unless (exists $description_seen{$option_key}
                    and defined $description_seen{$option_key}
                    and $description_seen{$option_key} > 0 
                ) {
                    _append_to_fetchwarefile(\$fetchwarefile, $option_key,
                        $option_value,
                        $self->{descriptions}->{$option_key});
                # Otherwise avoid duplicating the description.
                } else {
                    _append_to_fetchwarefile(\$fetchwarefile, $option_key,
                        $option_value);
                }
                vmsg <<EOM;
Appended [$option_key] configuration option [$option_value] to Fetchwarefile.
EOM
            } else {
                die <<EOD;
fetchware: fetchwarefile() was called to generate the Fetchwarefile you have
created using append_options_to_fetchwarefile(), but it has options in it that
do not have a description to add to the Fetchwarefile. Please add a description
to your call to fetchwarefile_config_options() for the option [$option_key].
EOD
            }
            # Increment this for each time each $option_key is written to the
            # $fetchwarefile to ensure that only on the very first time the
            # $option_key is written to the $fetchwarefile that its
            # description is also written.
            $description_seen{$option_key}++;
        }
    }
    return $fetchwarefile;
}


# It's an "_" internal subroutine, so don't publish its POD.
#=head3 _append_to_fetchwarefile()
#
#    _append_to_fetchwarefile(\$fetchwarefile, $config_file_option, $config_file_value, $description)
#
#Turns $description into a comment as described below, and then appends it to the
#$fetchwarefile. Then $config_file_option and $config_file_value are also
#appended inside proper Fetchwarefile syntax.
#
#$description is split into strings 78 characters long, and printed with C<# >
#prepended to make it a proper comment so fetchware skips parsing it.
#
#$description is optional. If you do not include it when you call
#_append_to_fetchwarefile(), then _append_to_fetchwarefile() will not add the
#provided description.
#
#=over
#
#=item NOTE
#Notice the backslash infront of the $fetchwarefile argument above. It is there,
#because the argument $fetchwarefile must be a reference to a scalar.
#
#=back
#
#=cut

sub _append_to_fetchwarefile {
    my ($fetchwarefile,
        $config_file_option,
        $config_file_value,
        $description) = @_;

    die <<EOD if ref($fetchwarefile) ne 'SCALAR';
fetchware: run-time error. You called _append_to_fetchwarefile() with a
fetchwarefile argument that is not a scalar reference. Please add the need
backslash reference operator to your call to _append_to_fetchwarefile() and try
again.
EOD


    # Only add a $description if we were called with one.
    if (defined $description) {
        # Append a double newline for easier reading, but only when we print a
        # new $description, which implies we're switching to a new configuration
        # option.
        $$fetchwarefile .= "\n\n";

        # Append a newline to $description if it doesn't have one already.
        $description .= "\n" unless $description =~ /\n$/;
        # Change wrap() to wrap at 80 columns instead of 76.
        local $Text::Wrap::columns = 81;
        # Use Text::Wrap's wrap() to split $description up
        $$fetchwarefile .= wrap('# ', '# ', $description);
    }

    # This simple chunk of regexes provide trivial and buggy support for
    # ONEARRREFs. This support simply causes fetchware to avoid adding any
    # characters that are needed for proper Perl syntax if the user has provided
    # those characters for us.
    if ($config_file_value =~ /('|")/) {
        $$fetchwarefile .= "$config_file_option $config_file_value";

        if ($config_file_value =~ /[^;]$/) {
            $$fetchwarefile .= ";"; 
        } elsif ($config_file_value =~ /[^\n]$/) {
            $$fetchwarefile .= "\n";
        }
    } else { 
        $$fetchwarefile .= "$config_file_option '$config_file_value';\n";
    }
}


1;

__END__

=pod

=head1 NAME

App::Fetchware::Fetchwarefile - Helps Fetchware extensions create Fetchwarefiles.

=head1 VERSION

version 1.014

=head1 SYNOPSIS

    use App::Fetchware::Fetchwarefile;

    # First create a new Fetchwarefile object.
    App::Fetchware::Fetchwarefile->new(
        header => <<EOF,
    use App::Fetchware;
    # Auto generated @{[localtime()]} by fetchware's new command.
    # However, feel free to edit this file if fetchware's new command's
    # autoconfiguration is not enough.
    # 
    # Please look up fetchware's documentation of its configuration file syntax at
    # perldoc App::Fetchware, and only if its configuration file syntax is not
    # malleable enough for your application should you resort to customizing
    # fetchware's behavior. For extra flexible customization see perldoc
    # App::Fetchware.
    EOF
        descriptions => {
            program => <<EOD,
    program simply names the program the Fetchwarefile is responsible for
    downloading, building, and installing.
    EOD
            temp_dir => <<EOD,
    temp_dir specifies what temporary directory fetchware will use to download and
    build this program.
    EOD
        
            ...
        }
    );

    ...

    # Then add whatever configuration options you need.
    $fetchwarefile->config_options(temp_dir => '/var/tmp');
    $fetchwarefile->config_options(no_install => 'True');
    $fetchwarefile->config_options(make_options => '-j 4');
    ...
    $fetchwarefile->config_options(
        temp_dir => 'var/tmp',
        program => 'Example',
        ...
        make_options => '-j $',
    );

    ...

    # Turn the Fetchwarefile object into a string or saving or executing.
    my $fetchwarefile_text = $fetchwarefile->generate();

=head1 DESCRIPTION

App::Fetchware::Fetchwarefile (Fetchwarefile) is an Object-Oriented Module that
allows you to programatically build an example Fetchwarefile for your user.

This is done by providing a "header" that will go first in your Fetchwarefile
that must include your Fetchware extension's C<use App::FetchwareX::...;> line,
and a "description", which is a hashref of configuration options and
descriptions for those configuration options. These "descriptions" will be
printed before each associate configuration option, so the user does not need to
read the documentation as much.

Next, you call config_options() as many times as needed to added whatever
condiguration options and their associated values to your Fetchwarefile.

Finally, you call generate(), which "generates" your Fetchwarefile by just
concatenating all of the different strings together making sure the whitespace
between them isn't screwed up.

=head1 FETCHWAREFILE METHODS

=head2 new()

    App::Fetchware::Fetchwarefile->new(
        header => <<EOF,
    use App::Fetchware;
    # Auto generated @{[localtime()]} by fetchware's new command.
    # However, feel free to edit this file if fetchware's new command's
    # autoconfiguration is not enough.
    # 
    # Please look up fetchware's documentation of its configuration file syntax at
    # perldoc App::Fetchware, and only if its configuration file syntax is not
    # malleable enough for your application should you resort to customizing
    # fetchware's behavior. For extra flexible customization see perldoc
    # App::Fetchware.
    EOF
        descriptions => {
            program => <<EOD,
    program simply names the program the Fetchwarefile is responsible for
    downloading, building, and installing.
    EOD
            temp_dir => <<EOD,
    temp_dir specifies what temporary directory fetchware will use to download and
    build this program.
    EOD
        
            ...
        }
    );

new() constructs new App::Fetchware::Fetchwarefile objects that represent
Fetchwarefiles. It uses per insance data instead of globals, so you can create
multiple Fetchwarefile objects if you want to, or need to in your test suite.

Both of its options C<header> and C<descriptions> are required, and must be a
faux hash instead of actual hashref to avoid another layer of annoying braces.

C<header> should be a string that is the header of your Fetchwarefile, which
just means it should be a message that includes your extension's
C<use App::FetchwareX::ExtensionName> as well as a brief comment block explaining
that this Fetchwarefile was autogenerated, and whatever helpful info you want to
add about it such as where the documentation for it is, and so on.

C<descriptions> should be a hashref whoose keys are this Fetchwarefile object's
associated App::Fetchware extension's configuration options. It must include all
of them. The values of these keys should be brief descriptions of each
configuration option intended to be prepended above each configuration option in
the generated Fetchwarefile.

The values of the keys of C<descriptions> are turned into a Fetchwarefile as
shown below...

    ...

    # program simply names the program the Fetchwarefile is responsible for
    # downloading, building, and installing.
    program 'my program';


    # temp_dir specifies what temporary directory fetchware will use to download and
    # build this program.
    temp_dir '/var/tmp';

    ...

=head2 config_options()

    $fetchwarefile->config_options(temp_dir => '/var/tmp');

    # And you can set multiple config options in one call.
    $fetchwarefile->config_options(
        temp_dir => 'var/tmp',
        program => 'Example',
        ...
        make_options => '-j $',
    );

config_options() should be used as needed to add whatever options to your
Fetchwarefile as needed. Can be called more than once for each configuration
option, and when it is, it promotes that key to an arrayref, and stores a list
of options. config_options() also supports adding multiple "values" to one
object in just one call to support C<MANY> type configuration options.

=head2 generate()

    my $fetchwarefile_text = $fetchwarefile->generate();

    print $fetchwarefile->generate();

generate() takes the header and descriptions that new() added to your
$fetchwarefile object along with whatever configuration options you have also
added to your $fetchwarefile object with config_option(), and generates and
returns a string that represents your Fetchwarefile. You can then change it as
needed, or just store it in a file for the user to use later on.

=head1 ERRORS

As with the rest of App::Fetchware, App::Fetchware::Config does not return any
error codes; instead, all errors are die()'d if it's App::Fetchware::Config's
error, or croak()'d if its the caller's fault.

=head1 AUTHOR

David Yingling <deeelwy@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by David Yingling.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
