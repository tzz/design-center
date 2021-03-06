#!/usr/bin/perl -w

######################################################################
my $VERSION="3.6.0";
my $DATE="2014";
######################################################################

BEGIN
{
    $ENV{PERL_JSON_BACKEND} = 'JSON::backportPP';

    if ($0 =~ m/design_center$/)
    {
        unshift @ARGV, '--module_mode';
    }

    if (-l $0)
    {
        require FindBin;
        $0 = readlink $0;
        FindBin->again();
    }
}

my @toremove;
my $inputs_root;

use File::Basename;
use FindBin;
use lib map { $_,
               "$_/File-Path-2.09",
               "$_/File-Which-1.09/lib",
               "$_/JSON-2.53/lib",
               "$_/Mo-0.31/lib" }
 ("$FindBin::Bin/perl-lib", "$FindBin::Bin/../lib/cf-sketch/perl-lib");

use warnings;
use strict;
use DCAPI;
use Util;
use File::Temp qw/tempfile tempdir /;
use Parser;
use Data::Dumper;

$| = 1;                                 # autoflush

# for encode/decode, not to use it directly!!!
my $dcapi = DCAPI->new(cfengine_min_version => 1);

use Getopt::Long;

my %options = (
               environment => 'cf_sketch_testing',
               activate => {},
               install => [],
               apitest => [],
               coverage => 0,
               uninstall => [],
               filter => [],
               force => 0,
               quiet => 0,
               verbose => 0,
               ignore => 1,
               activated => 'any',
               veryverbose => 0,
               installsource => Util::local_cfsketches_source(File::Spec->curdir()) || 'https://raw.githubusercontent.com/cfengine/design-center/master/sketches/cfsketches.json',
               # These are hardcoded above, we put them here for convenience
               version => $VERSION,
               date => $DATE,
               dcapi => $dcapi,
               inputs => '/var/cfengine/masterfiles',
               standalonerunfile => '/var/cfengine/masterfiles/cf-sketch-runfile-standalone.cf',
              );

Getopt::Long::Configure("bundling", "require_order");

GetOptions(\%options,
           "expert!",
           "quiet|q!",
           "ignore!",
           "coverage!",
           "verbose|v!",
           "module_mode!",
           "veryverbose|vv!",
           "generate!",
           "force|f!",
           "activated:s",
           "installsource|is=s",
           "cfpath=s",
           "list:s",
           "search:s",
           "make_readme:s",
           "make_cfsketches:s",
           "filter=s@",
           "install|i=s@",
           "install-all|ia",
           "apitest=s@",
           "apiconfig=s",
           "uninstall=s@",
           "deactivate-all|da",
           "activate|a=s%",
           "inputs=s",
           "relocate_path:s",

           "runfile_header=s",
          );

die "$0: --installsource FILE must be specified" unless $options{installsource};

mkdir $options{inputs} unless -d $options{inputs}; # try to create...
die "$0: --inputs $options{inputs} doesn't exist" unless -d $options{inputs};

$options{installdest}="$options{inputs}/sketches";

my $sourcedir;
set_installsource_sourcedir($options{installsource});

if (exists $options{'make_cfsketches'})
{
    # do nothing in this case
}
elsif (Util::is_resource_local($options{installsource}))
{
    die "$0: $options{installsource} is not a file" unless (-f "$options{installsource}");
    die "Sorry, can't locate source directory" unless -d $sourcedir;
}
else
{
    my $remote = Util::get_remote($options{installsource});
    die "Could not retrieve remote URL $options{installsource}, aborting"
        unless $remote;

    warn <<EOHIPPUS;

You are using a remote sketch repository ($options{installsource}),
which may be slow.  If you run cf-sketch with the --installsource option
pointing to cfsketches.json, or run it in your Design Center checkout directory,
or give the DC API a config.json with a 'recognized_source' parameter, it will
find your local Design Center checkout more easily and avoid network queries

EOHIPPUS
}

$options{verbose} = 1 if $options{veryverbose};

# Define default internal environment
$options{activated} = 'any' if !$options{activated};
my $env_activated = $options{activated};

api_interaction({
                 define_environment => {
                                        $options{environment} =>
                                        {
                                         activated => $env_activated,
                                         verbose => $options{verbose} ? 'any' : '!any',
                                        }
                                       }
                });

if (exists $options{'make_readme'})
{
    api_interaction({
                     describe => 'README',
                     search => $options{search} || '.'
                    },
                    make_readme_saver('search', 'README.md'));
    exit 0;
}

if (exists $options{'make_cfsketches'})
{
    api_interaction({
                     regenerate_index => $options{sourcedir},
                    });
    exit 0;
}

if (exists $options{module_mode})
{
    $options{expert} = 1;
    cfe_module_interaction(@ARGV);
}

if (exists $options{'search'})
{
    api_interaction({
                     describe => 1,
                     search => $options{search} eq '' ? '.' : $options{search}
                    },
                    make_list_printer('search'));
}

if (exists $options{'list'})
{
    api_interaction({
                     describe => 1,
                     list => $options{list} eq '' ? '.' : $options{list}
                    },
                    make_list_printer('list'));
}

if ($options{'deactivate-all'})
{
    api_interaction({deactivate => 1});
}

if ($options{'install-all'})
{
    $options{force} = 1; # because the dependencies will need to be overwritten
    my ($success, $result) = api_interaction({
                                              search => '.'
                                             },
                                             make_cfdc_upgrade('search'));

    exit 0 if $success;

    exit 1;
}

if (scalar @{$options{install}})
{
    my @names;                          # sketch names
    foreach (@{$options{install}})
    {
        push @names, split ',', $_;
    }

    install_sketches(@names);
}

if (scalar @{$options{apitest}})
{
    my @todo;
    foreach (@{$options{apitest}})
    {
        push @todo, join('|', split ',', $_);
    }

    my ($success, $result) = api_interaction({test => \@todo,
                                              coverage => $options{coverage}});

    exit 0 if $success;

    exit 1;
}

if (scalar @{$options{uninstall}})
{
    my @todo = map
    {
        {
            sketch => $_, target => undef,
         }
    } @{$options{uninstall}};
    api_interaction({uninstall => \@todo}, undef, undef, [qw/target/]);
}

if (scalar keys %{$options{activate}})
{
    my %todefine;
    my %todo;
    foreach my $sketch (keys %{$options{activate}})
    {
        next if $sketch eq 'pname';

        my $file = $options{activate}->{$sketch};

        my $load = $file;
        my @warnings;

        if (ref $load ne 'ARRAY')
        {
            $file =~ s/^'(.+)'$/$1/;
            if (substr($file, 0, 1) eq '{')
            {
                ($load, @warnings) = $dcapi->decode($file);
                die "Could not decode JSON string '$file': @warnings" unless defined $load;
                unless (Util::hashref_search($load, $sketch))
                {
                    $load = { $sketch => $load };
                }
            }
            else
            {
                ($load, @warnings) = $dcapi->load($file);
                die "Could not load $file: @warnings" unless defined $load;
            }
        }

        if (ref $load eq 'ARRAY')
        {
            my $i = 1;
            foreach (@$load)
            {
                my $pname = exists $options{activate}->{pname} ? $options{activate}->{pname} : $file;

                my $k = exists $options{activate}->{pname} ? $options{activate}->{pname} : "parameter definition from $file-$i";
                $todefine{$k} = $_;
                $i++;
                push @{$todo{$sketch}},{
                                        environment => $options{environment},
                                        params => [ $k ],
                                        target => undef,
                                       };
            }
        }
        else
        {
            my $k = "parameter definition from $file";
            $todefine{$k} = $load;
            push @{$todo{$sketch}},{
                                    environment => $options{environment},
                                    params => [ $k ],
                                    target => undef,
                                   };
        }
    }

    api_interaction({define => \%todefine});

    foreach my $sketch (keys %todo)
    {
        foreach my $activation (@{$todo{$sketch}})
        {
            api_interaction({activate => { $sketch => $activation }}, undef, undef, [qw/target/]);
        }
    }
}

if ($options{'generate'})
{
    api_interaction({regenerate => 1});
}

unless ($options{'expert'}) {
    use Term::ANSIColor qw(:constants);
    $Term::ANSIColor::AUTORESET = 1;

    # Determine where to load command modules from
    (-d ($options{'cmddir'}="$FindBin::Bin/../lib/cf-sketch/perl-lib/Parser/Commands")) ||
    (-d ($options{'cmddir'}="$FindBin::Bin/perl-lib/Parser/Commands")) ||
    ($options{'cmddir'}=undef);

    # Load commands and do other parser initialization
    Parser::init('cf-sketch', \%options, @ARGV);
    Parser::set_welcome_message("[default]\nCFEngine AS, 2013.");

    # Run the main command loop
    Parser::parse_commands();

    # Finishing code.
    Parser::finish();

    exit(0);
}

sub set_installsource_sourcedir
{
    $options{installsource} = shift @_;

    $sourcedir = dirname($options{installsource});
    $options{sourcedir} = $sourcedir;
}

sub api_interaction
{
    my $request = shift @_;
    my $callback = shift @_;
    my $mergeopts = shift @_;
    my $request_fill = shift @_;

    my $mydir = dirname($0);
    my $api_bin = "$mydir/cf-dc-api.pl";

    my ($fh_config, $filename_config) = tempfile( "./cf-dc-api-run-XXXX", TMPDIR => 1 );
    my ($fh_data, $filename_data) = tempfile( "./cf-dc-api-run-XXXX", TMPDIR => 1 );

    my $log_level = 0;
    $log_level = 4 if $options{verbose};
    $log_level = 5 if $options{veryverbose};

    my $opts = {
                log => "pretty",
                log_level => $log_level,
                repolist => [ "$options{installdest}" ],
                recognized_sources =>
                [
                 $sourcedir
                ],
                runfile =>
                {
                 filter_inputs => $options{filter},
                },
               };

    if (exists $options{runfile_header})
    {
        $opts->{runfile}->{header} = $options{runfile_header};
    }

    if (exists $options{relocate_path})
    {
        $opts->{runfile}->{relocate_path} = $options{relocate_path};
    }

    if (exists $options{make_cfsketches} || exists $options{make_readme})
    {
        $opts->{vardata} = '-';
    }

    if (exists $options{apiconfig})
    {
        my $error;
        print STDERR ">> OVERRIDING CONFIG FROM $options{apiconfig}\n" if $options{verbose};
        ($opts, $error) = $dcapi->load($options{apiconfig});
        die $error if defined $error;
    }

    # Merge passed options, if any
    if ($mergeopts) {
      for my $k (keys %$mergeopts) {
        $opts->{$k} = $mergeopts->{$k};
      }
    }
    my $config = $dcapi->cencode($opts);
    print STDERR ">> $config\n" if $options{verbose};
    print $fh_config "$config\n";
    close $fh_config;

    if (defined $request_fill)
    {
        foreach my $fill (@$request_fill)
        {
            my $data;
            if ($fill eq 'source')
            {
                $data = $sourcedir;
            }
            elsif ($fill eq 'target')
            {
                $data = "$options{inputs}/sketches";
            }
            else
            {
                warn "Unknown request fill $fill!";
                next;
            }

            replace_attribute($request, $fill, $data);
        }
    }

    my $data = $dcapi->cencode({
                                dc_api_version => "3.6.0",
                                request => $request,
                               });
    print STDERR ">> $data\n" if $options{verbose};
    print $fh_data "$data\n";
    close $fh_data;

    print STDERR "Running [$api_bin '$filename_config' '$filename_data']\n"
     if $options{veryverbose};
    open my $api, '-|', "$api_bin '$filename_config' '$filename_data'" or die "Could not open $api_bin: $!";

    my $result;
    while (<$api>)
    {
        print "<< $_" if $options{verbose};
        $result = $dcapi->load($_);
    }
    close $api;
    unlink $filename_config, $filename_data;

    my $ok = Util::hashref_search($result, 'api_ok');
    if ($ok)
    {
        $result = $ok;
        my $success = Util::hashref_search($result, 'success');
        if ($success)
        {
            Util::success("OK: Got successful result: ".$dcapi->encode($result)."\n")
             if $options{verbose};
            Util::print_api_messages($result);
        }
        else
        {
            print STDERR "OK: Got unsuccessful result: ".$dcapi->encode($result)."\n"
              if $options{verbose};
            Util::print_api_messages($result);
        }

        unless (defined $callback)
        {
            $callback = sub
            {
                my $success = shift @_;
                my $result = shift @_;
                if (!$success && !$options{ignore})
                {
                    exit 1;
                }
            };
        }

        $callback->($success, $result) if defined $callback;

        return ($success, $result);
    }
    elsif (my $errors = Util::hashref_search($result, qw/api_error errors/))
    {
        Util::error("API fatal error: @{[ join ';', @$errors ]}\n");
    }
    else
    {
        Util::error("API fatal error: Got bad result: ".$dcapi->encode($result)."\n");
    }
    exit 1;
    # return (0, $result);
}

sub replace_attribute
{
     my $container = shift @_;
     my $fill = shift @_;
     my $data = shift @_;

     return unless defined $container;

     if (ref $container eq 'HASH')
     {
         if (exists $container->{$fill})
         {
             $container->{$fill} = $data;
             return;
         }

         replace_attribute($_, $fill, $data) foreach values %$container;
     }
     elsif (ref $container eq 'ARRAY')
     {
         replace_attribute($_, $fill, $data) foreach @$container;
     }
}

sub install_sketches
{
    my @todo = map
    {
        {
            sketch => $_, force => $options{force}, source => undef, target => undef
        }
    } @_;
    api_interaction({install => \@todo}, undef, undef, [qw/source target/]);
}

sub uninstall_sketches
{
    my @todo = map
    {
        {
            sketch => $_, force => $options{force}, source => undef, target => undef
        }
    } @_;
    api_interaction({uninstall => \@todo}, undef, undef, [qw/source target/]);
}

sub make_cfdc_upgrade
{
    my $type = shift @_;
    my @names;

    return make_list_processor($type,
                               sub
                               {
                                   my $item = shift @_;
                                   die "Unexpected non-scalar item in list printer"
                                    unless ref $item eq '';

                                   push @names, $item;
                               },
                               sub
                               {
                                   install_sketches(@names);
                               });
}

sub make_list_printer
{
    my $type = shift @_;

    return make_list_processor($type,
                               sub
                               {
                                   my $item = shift @_;
                                   die "Unexpected item in list printer $item"
                                    unless ref $item eq 'HASH';

                                   my $name = Util::hashref_search($item, qw/metadata name/);
                                   my $desc = Util::hashref_search($item, qw/metadata description/);
                                   print "$name $desc\n";
                               });
}

sub make_readme_saver
{
    my $type = shift @_;
    my $target_file = shift @_;

    return make_list_processor($type,
                               sub
                               {
                                   my $item = shift @_;
                                   die "Unexpected item in README saver"
                                    unless ref $item eq 'ARRAY';

                                   my ($dir, $content) = @$item;
                                   my $file = "$dir/$target_file";
                                   open my $f, '>', $file
                                    or die "Could not write $file: $!";
                                   print $f $content;
                                   close $f;
                                   print "wrote $file...\n";
                               });
}

sub make_list_processor
{
    my $type = shift @_;
    my $proc = shift @_;
    my $post = shift @_;

    return sub
    {
        my $ok = shift @_;
        my $result = shift @_;
        my $list = Util::hashref_search($result, 'data', $type);
        if (ref $list eq 'HASH')
        {
            foreach my $repo (sort keys %$list)
            {
                foreach my $sketch (values %{$list->{$repo}})
                {
                    $proc->($sketch);
                }
            }
        }

        $post->() if $post;
    }
}

# Common API actions

# Return details of sketches according to regex. Without args returns all sketches
sub get_all_sketches {
  my $regex = Util::validate_and_set_regex(shift);
  my ($success, $result) = main::api_interaction({
                                                  describe => 1,
                                                  search => $regex,
                                                 });
  my $list = Util::hashref_search($result, 'data', 'search');
  my $res = {};
  if (ref $list eq 'HASH')
  {
    foreach my $repo (keys %$list) {
      foreach my $sketch (keys %{$list->{$repo}}) {
        $res->{$sketch} = $list->{$repo}->{$sketch};
      }
    }
  }
  else
  {
    Util::error("Internal error: The API 'search' command returned an unknown data structure.");
  }
  return $res;
}

# Alias for get_all_sketches
sub get_sketch
{
    my $sketch = shift;
    return Util::hashref_search(get_all_sketches($sketch), $sketch);
}

# Return list of installed sketches and their repositories
sub get_installed {
    my ($success, $result) = main::api_interaction({
                                                 describe => 0,
                                                 list => '.',
                                                });
    my $list = Util::hashref_search($result, 'data', 'list');
    my $installed = {};
    if (ref $list eq 'HASH')
    {
        foreach my $repo (keys %$list)
        {
            foreach my $sketch (keys %{$list->{$repo}})
            {
                $installed->{$sketch} = $repo;
            }
        }
    }
    else
    {
        Util::error("Internal error: The API 'list' command returned an unknown data structure.");
    }
    return $installed;
}

# Return whether a sketch is installed
sub is_sketch_installed
{
  my $sketch = shift;
  my $installed = get_installed;
  return $installed->{$sketch} if exists $installed->{$sketch};
}

# Return all activations
sub get_activations {
    my $sketch = shift @_;
    my $pname = shift @_;

    my ($success, $result) = main::api_interaction({ activations => 1 });
    my $activs = Util::hashref_search($result, 'data', 'activations');
    if (ref $activs eq 'HASH')
    {
        if (defined $sketch)
        {
            my $sketch_activs = Util::hashref_search($activs, $sketch);
            if (ref $sketch_activs eq 'ARRAY' && defined $pname)
            {
                    foreach my $a (@$sketch_activs)
                    {
                        foreach my $p (@{$a->{params}})
                        {
                            if ($p eq $pname)
                            {
                                return $a;
                            }
                        }
                    }

                    return undef;
            }
            else
            {
                return $sketch_activs;
            }
        }
        else
        {
            return $activs;
        }
    }
    else
    {
        Util::error("Internal error: The API 'activations' command returned an unknown data structure.");
        return undef;
    }
}

# Return all parameter definitions
sub get_definitions {
  my ($success, $result) = main::api_interaction({ definitions => 1 });
  return unless $success;
  my $defs = Util::hashref_search($result, 'data', 'definitions');
  if (ref $defs eq 'HASH') {
    return $defs;
  }
  else {
    Util::error("Internal error: The API 'definitions' command returned an unknown data structure.");
    return undef;
  }
}

# Return all environment definitions
sub get_environments {
  my ($success, $result) = main::api_interaction({ environments => 1 });
  return unless $success;
  my $envs = Util::hashref_search($result, 'data', 'environments');
  $envs = {} unless (ref $envs eq 'HASH');
  return $envs;
}

# Get all validations
sub get_validations {
  my ($success, $result) = main::api_interaction({ validations => 1 });
  return unless $success;
  my $vals = Util::hashref_search($result, 'data', 'validations');
  $vals = {} unless (ref $vals eq 'HASH');
  return $vals;
}

###################################################################
# Package Module Interface ########################################
###################################################################

sub cfe_module_interaction_package_from_sketch
{
    my $data = shift @_;
    my $showtype = shift @_;

    my $name = Util::hashref_search($data, qw/metadata name/);

    die "Unexpected error: sketch data is missing a name " . $dcapi->cencode($data)
     unless $name;
    print "Name=$name\n";

    my $version = Util::hashref_search($data, qw/metadata version/) || 0;
    print "Version=$version\n";
    print "Architecture=none\n";

    print "PackageType=repo\n" if $showtype;
}

sub cfe_module_interaction_read
{
    my %in;
    while (<STDIN>)
    {
        chomp;
        my ($k, $v) = split '=', $_, 2;
        if ($k eq 'options')
        {
            cfe_module_special_options(split '=', $v, 2);
        }
        else
        {
            push @{$in{$k}}, $v;
        }
    }

    return \%in;
}

sub cfe_module_special_options
{
    my $k = shift @_;
    my $v = shift @_;

    if ($k eq 'installsource')
    {
        set_installsource_sourcedir($v);
    }
    elsif ($k eq 'verbose' || $k eq 'veryverbose')
    {
        $options{$k} = $v;
    }
}

sub cfe_module_interaction
{
    my @args = @_;

    foreach my $command (@args)
    {
        if ($command eq 'supports-api-version')
        {
            print "1\n";
        }
        else
        {
            my $conf = cfe_module_interaction_read();
            if ($options{veryverbose})
            {
                warn "{{{ $0: $command config: " . Dumper($conf);
            }

            if ($command eq 'get-package-data')
            {
                my $file = Util::hashref_search($conf, 'File');

                die "$0: no 'File' parameters given, aborting"
                 unless ref $file eq 'ARRAY';

                die "$0: multiple 'File' parameters are not supported, aborting"
                 unless scalar @$file == 1;

                my $sketch = $file->[0];
                my $found = get_sketch($sketch);

                if ($found)
                {
                    cfe_module_interaction_package_from_sketch($found, 1);
                }
                else
                {
                    print STDERR "ErrorMessage=Sketch '$sketch' was not found in $options{installsource}\n";
                    exit 1;
                }
            }
            elsif ($command eq 'list-installed')
            {
                my $installed = get_installed();
                if (defined $installed && ref $installed eq 'HASH')
                {
                    foreach my $sketch (sort keys %$installed)
                    {
                        cfe_module_interaction_package_from_sketch(get_sketch($sketch), 0);
                    }
                }
            }
            elsif ($command eq 'list-updates')
            {
                # TODO
            }
            elsif ($command eq 'list-updates-local')
            {
                # TODO
            }
            elsif ($command eq 'repo-install' || $command eq 'remove')
            {
                my $remove_mode = ($command eq 'remove');
                my $name = Util::hashref_search($conf, 'Name');

                die "$0: no 'Name' parameters given, aborting"
                 unless ref $name eq 'ARRAY';

                die "$0: multiple 'Name' parameters are not supported, aborting"
                 unless scalar @$name == 1;

                my $sketch = $name->[0];

                if ($remove_mode)
                {
                    if (is_sketch_installed($sketch))
                    {
                        uninstall_sketches($sketch);
                    }

                    if (is_sketch_installed($sketch))
                    {
                        print STDERR "ErrorMessage=Sorry, could not remove sketch '$sketch' from $options{installsource}\n";
                        exit 1;
                    }
                }
                else # install mode
                {
                    unless (is_sketch_installed($sketch))
                    {
                        install_sketches($sketch);
                    }

                    unless (is_sketch_installed($sketch))
                    {
                        print STDERR "ErrorMessage=Sorry, could not install sketch '$sketch' from $options{installsource}\n";
                        exit 1;
                    }
                }
            }
            else
            {
                die "Unknown command: $command";
            }
        }
    }

    exit 0;
}
