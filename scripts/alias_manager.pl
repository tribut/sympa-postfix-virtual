#!/usr/bin/perl
# alias_manager.pl -  this script is intended to create automatically list aliases
# when using sympa. Aliases can be added or removed in file --SENDMAIL_ALIASES--
# To use a different script, you should edit the 'alias_manager' sympa.conf parameter

# RCS Identication ; $Revision: 6556 $ ; $Date: 2010-06-21 18:01:01 +0200 (lun 21 jun 2010) $ 

# L. Marcotte has written a version of alias_manager.pl that is LDAP enabled
# check the contrib. page for more information :
# http://sympa.org/contrib.html

# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

# Modified to generate virtual alias files for Postfix virtual alias domains
# Elwyn Davies 4 April 2008

# Updated to current version of alias_manager.pl
# Felix Eckhofer 21 July 2013

$ENV{'PATH'} = '';

## Load Sympa.conf
use strict;
use lib '/usr/share/sympa/lib';
use Conf;
use POSIX;
use tools;
use tt2;
use Sympa::Constants;

my $sympa_conf_file = Sympa::Constants::CONFIG;
unless (Conf::load($sympa_conf_file)) {
   print STDERR "The configuration file $sympa_conf_file contains errors.\n";
   exit(1);
}
my $tmp_alias_file = $Conf{'tmpdir'}.'/sympa_aliases.'.time;


my $default_domain;
my $virtual_domain      = 0;
my $alias_wrapper       = Sympa::Constants::SBINDIR . '/aliaswrapper';
my $postmap             = '/usr/sbin/postmap'; # debian default
my $lock_file           = Sympa::Constants::EXPLDIR . '/alias_manager.lock';
my $path_to_queue       = Sympa::Constants::LIBEXECDIR . '/queue';
my $path_to_bouncequeue = Sympa::Constants::LIBEXECDIR .'/bouncequeue';

my ($operation, $listname, $domain, $file) = @ARGV;


if (($operation !~ /^(add|del)$/) || ($#ARGV < 2)) {
    printf STDERR "Usage: $0 <add|del> <listname> <robot> [<file>]\n";
    exit(2);
}

$default_domain = $Conf{'domain'};

my $alias_file = $Conf{'sendmail_aliases'} || Sympa::Constants::SENDMAIL_ALIASES;
$alias_file = $file if ($file);
$virtual_domain = 1 if ($alias_file =~ /virtual$/);
my $pt; # pattern type for alias matching
if ($virtual_domain != 0) {
    $pt = 1;
} else {
    $pt = 0;
}

unless (-w "$alias_file") {
    print STDERR "Unable to access $alias_file\n";
    exit(5);
}
    
my %data;
$data{'date'} =  &POSIX::strftime("%d %b %Y", localtime(time));


$data{'list'}{'domain'} = $data{'robot'} = $domain;
$data{'list'}{'domainescaped'} = $domain;
$data{'list'}{'domainescaped'} =~ s/\./\\\./g;
$data{'list'}{'name'} = $listname;
$data{'default_domain'} = $default_domain;
$data{'is_default_domain'} = 1 if ($domain eq $default_domain);
$data{'is_virtual_domain'} = 1 if ($virtual_domain != 0);
$data{'return_path_suffix'} = &Conf::get_robot_conf($domain, 'return_path_suffix');


my @aliases ;

my $tt2_include_path = &tools::make_tt2_include_path($domain,'',,);

my $aliases_dump;
&tt2::parse_tt2 (\%data, 'list_aliases.tt2',\$aliases_dump, $tt2_include_path);

@aliases = split /\n/, $aliases_dump;

unless (@aliases) {
    	print STDERR "No aliases defined\n";
	exit(15);
}

if ($operation eq 'add') {
    ## Create a lock
    unless (open(LF, ">>$lock_file")) { 
	print STDERR "Can't open lock file $lock_file\n";
	exit(14);
    }
    flock LF, 2;

    ## Check existing aliases
    if (&already_defined($pt, @aliases)) {
	printf STDERR "some alias already exist\n";
	exit(13);
    }

    unless (open  ALIAS, ">> $alias_file") {
	print STDERR "Unable to append to $alias_file\n";
	exit(5);
    }

    foreach (@aliases) {
	print ALIAS "$_\n";
    }
    close ALIAS;

    ## Newaliases and postmap unless specifying file on command line
    unless ($file) {
        ## Postmap if doing a virtual domain
        if ($virtual_domain != 0) {
            unless(system($postmap, $alias_file) == 0) {
                print STDERR "Failed to execute postmap for $alias_file: $!\n";
                exit(6);
            }
        } else {
            unless (system($alias_wrapper) == 0) {
                print STDERR "Failed to execute newaliases: $!\n";
                exit(6);
            }
        }
    }

    ## Unlock
    flock LF, 8;
    close LF;

}elsif ($operation eq 'del') {

    ## Create a lock
    open(LF, ">>$lock_file") || die "Can't open lock file $lock_file";
    flock LF, 2;

    unless (open  ALIAS, "$alias_file") {
	print STDERR "Could not read $alias_file\n";
	exit(7);
    }
    
    unless (open NEWALIAS, ">$tmp_alias_file") {
	printf STDERR "Could not create $tmp_alias_file\n";
	exit (8);
    }

    my @deleted_lines;
    while (my $alias = <ALIAS>) {
	my $left_side = '';
	if ($pt == 0) {
		$left_side = $1 if ($alias =~ /^([^:]+):/);
	} else {
		$left_side = $1 if ($alias =~ /^([^\t ]+)[ \t]/);
	}

	my $to_be_deleted = 0;
	foreach my $new_alias (@aliases) {
		next unless ((($pt == 0) && ($new_alias =~ /^([^:]+):/)) ||
			(($pt == 1) && ($new_alias =~ /^([^\t ]+)[ \t]/)));
	    my $new_left_side = $1;
	    
	    if ($left_side eq  $new_left_side) {
		push @deleted_lines, $alias;
		$to_be_deleted = 1 ;
		last;
	    }
	}
	unless ($to_be_deleted)  {
	    ## append to new aliases file
	    print NEWALIAS $alias;
	}
    }
    close ALIAS ;
    close NEWALIAS;
    
    if ($#deleted_lines == -1) {
	print STDERR "No matching line in $alias_file\n" ;
	exit(9);
    }
    ## replace old aliases file
    unless (open  NEWALIAS, "$tmp_alias_file") {
	print STDERR "Could not read $tmp_alias_file\n";
	exit(10);
    }
    
    unless (open OLDALIAS, ">$alias_file") {
	print STDERR "Could not overwrite $alias_file\n";
	exit (11);
    }
    print OLDALIAS <NEWALIAS>;
    close OLDALIAS ;
    close NEWALIAS;
    unlink $tmp_alias_file;

    ## Newaliases and postmap unless specifying file on command line
    unless ($file) {
        ## Postmap if doing a virtual domain
        if ($virtual_domain != 0) {
            unless(system($postmap, $alias_file) == 0) {
                print STDERR "Failed to execute postmap for $alias_file: $!\n";
                exit(6);
            }
        } else {
            unless (system($alias_wrapper) == 0) {
                print STDERR "Failed to execute newaliases: $!\n";
                exit(6);
            }
        }
    }
    ## Unlock
    flock LF, 8;
    close LF;

}else {
    print STDERR "Action $operation not implemented yet\n";
    exit(2);
}

exit 0;

## Check if an alias is already defined  
sub already_defined {
	# pt is 'pattern type' - 0 for oridnary aliases, 1 for virtual regexp aliases
	my ($pt, @aliases) = @_;
    
    unless (open  ALIAS, "$alias_file") {
	printf STDERR "Could not read $alias_file\n";
	exit (7);
    }

	my $left_side = '';
	my $new_left_side = '';
    while (my $alias = <ALIAS>) {
	# skip comment
	next if $alias =~ /^#/ ; 
	if ($pt == 0) {
		$alias =~ /^([^:]+):/;
		$left_side = $1;
	} else {
		$alias =~ /^([^\t ]+)[ \t]/;
		$left_side = $1;
	}
	next unless ($left_side);
	foreach (@aliases) {
		next unless ((($pt == 0) && ($_ =~ /^([^:]+):/)) ||
			(($pt == 1) && ($_ =~ /^([^\t ]+)[ \t]/)));
		$new_left_side = $1;
	    if ($left_side eq  $new_left_side) {
		print STDERR "Alias already defined : $left_side\n";
		return 1;
	    }
	}	
    }
    
    close ALIAS ;
    return 0;
}

