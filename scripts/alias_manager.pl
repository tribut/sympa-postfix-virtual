#!/usr/bin/perl
# alias_manager.pl -  this script is intended to create automatically list aliases
# when using sympa. Aliases can be added or removed in file --SENDMAIL_ALIASES--
# To use a different script, you should edit the 'alias_manager' sympa.conf parameter

 # -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id: alias_manager.pl.in 12612 2016-01-01 01:48:29Z sikeda $

# L. Marcotte has written a version of alias_manager.pl that is LDAP enabled
# check the contrib. page for more information :
# http://sympa.org/contrib.html

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014, 2015, 2016 GIP RENATER
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
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Modified to generate virtual alias files for Postfix virtual alias domains
# Elwyn Davies 4 April 2008

# Updated to current version of alias_manager.pl
# Felix Eckhofer 21 July 2013

# Updated to Sympa 6.2.16
# Peter Putzer 23 January 2016 and 11 March 2017


use lib split(/:/, $ENV{SYMPALIB} || ''), '/usr/libexec/sympa';
use strict;
use warnings;
use English qw(-no_match_vars);
use Getopt::Long;
use Pod::Usage;

use Conf;
use Sympa::Constants;
use Sympa::Crash;    # Show traceback.
use Sympa::Language;
use Sympa::LockedFile;
use Sympa::Log;
use Sympa::Template;

$ENV{'PATH'} = '';

my %options;
GetOptions(\%main::options, 'help|h');

if ($main::options{'help'}) {
    pod2usage(0);
}

## Load Sympa.conf
unless (defined Conf::load()) {
    printf STDERR
        "Unable to load sympa configuration, file %s or one of the vhost robot.conf files contain errors. Exiting.\n",
        Conf::get_sympa_conf();
    exit 1;
}

my $log = Sympa::Log->instance;
$log->{level} = $Conf::Conf{'log_level'};
$log->openlog($Conf::Conf{'syslog'}, $Conf::Conf{'log_socket_type'});

my $tmp_alias_file = $Conf::Conf{'tmpdir'} . '/sympa_aliases.' . time;

my $default_domain;
my $virtual_domain      = 0;
my $alias_wrapper =
    Sympa::Constants::LIBEXECDIR . '/sympa_newaliases-wrapper';
my $path_to_queue       = Sympa::Constants::LIBEXECDIR . '/queue';
my $path_to_bouncequeue = Sympa::Constants::LIBEXECDIR . '/bouncequeue';

my $lock_file = Sympa::Constants::PIDDIR() . '/alias_manager.lock';
my $lock_fh;

my ($operation, $listname, $domain, $file) = @ARGV;

if (($operation !~ /^(add|del)$/) || ($#ARGV < 2)) {
    printf STDERR "Usage: $0 <add|del> <listname> <robot> [<file>]\n";
    exit(2);
}

$default_domain = $Conf::Conf{'domain'};

my $alias_file;
$alias_file = Conf::get_robot_conf($domain, 'sendmail_aliases')
    || Sympa::Constants::SENDMAIL_ALIASES;
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

my $language = Sympa::Language->instance;
$language->set_lang(Conf::get_robot_conf($domain, 'lang'),
    $Conf::Conf{'lang'}, 'en');

my $data = {
    'date' => $language->gettext_strftime('%d %b %Y', localtime time),
    'list' => {
        'domain' => $domain,
        'domainescaped' => ($domain =~ s/\./\\\./gr),
        'name'   => $listname,
    },
    'robot'             => $domain,
    'default_domain'    => $default_domain,
    'is_default_domain' => ($domain eq $default_domain),
    'is_virtual_domain' => ($virtual_domain != 0),
    'return_path_suffix' =>
        Conf::get_robot_conf($domain, 'return_path_suffix'),
};

my @aliases;

my $aliases_dump;
my $template = Sympa::Template->new($domain);
unless ($template->parse($data, 'list_aliases.tt2', \$aliases_dump)) {
    print STDERR "Can't parse list_aliases.tt2\n";
    exit 15;
}

@aliases = split /\n/, $aliases_dump;

unless (@aliases) {
    print STDERR "No aliases defined\n";
    exit(15);
}

if ($operation eq 'add') {
    # Create a lock
    unless ($lock_fh = Sympa::LockedFile->new($lock_file, 5, '+')) {
        print STDERR "Can't lock $lock_file\n";
        exit 14;
    }

    ## Check existing aliases
    if (already_defined($pt, @aliases)) {
        printf STDERR "some alias already exist\n";
        exit(13);
    }

    unless (open ALIAS, ">> $alias_file") {
        print STDERR "Unable to append to $alias_file\n";
        exit(5);
    }

    foreach (@aliases) {
        print ALIAS "$_\n";
    }
    close ALIAS;

    ## Newaliases
    unless ($file || $virtual_domain != 0) {
        unless (system($alias_wrapper, "--domain=$domain") == 0) {
            if ($? == -1) {
                print STDERR "Failed to execute newaliases: $ERRNO\n";
            } else {
                printf STDERR "newaliases exited with status %d\n", ($? >> 8);
            }
            exit(6);
        }
    }

    # Unlock
    $lock_fh->close;
} elsif ($operation eq 'del') {
    # Create a lock
    unless ($lock_fh = Sympa::LockedFile->new($lock_file, 5, '+')) {
        print STDERR "Can't lock $lock_file";
        exit 14;
    }

    unless (open ALIAS, "$alias_file") {
        print STDERR "Could not read $alias_file\n";
        exit(7);
    }

    unless (open NEWALIAS, ">$tmp_alias_file") {
        printf STDERR "Could not create $tmp_alias_file\n";
        exit(8);
    }

    my @deleted_lines;
    while (my $alias = <ALIAS>) {
        my $left_side = '';
        if ($pt == 0) {
			$left_side = $1 if ($alias =~ /^([^\s:]+)[\s:]/);
		} else {
			$left_side = $1 if ($alias =~ /^([^\t ]+)[\t ]/);
			$left_side = $1 if ($alias =~ /^(#[^\s:]+)[\s:]/);
		}

        my $to_be_deleted = 0;
        foreach my $new_alias (@aliases) {
            my $new_left_side = $1;
	        if ($pt == 0) {
	            $new_left_side = $1 if ($new_alias =~ /^([^\s:]+)[\s:]/);
	        } else {
	            $new_left_side = $1 if ($new_alias =~ /^([^\t ]+)[\t ]/);
	            $new_left_side = $1 if ($new_alias =~ /^(#[^\s:]+)[\s:]/);
	        }
	        next unless $new_left_side;

            if ($left_side eq $new_left_side) {
                push @deleted_lines, $alias;
                $to_be_deleted = 1;
                last;
            }
        }
        unless ($to_be_deleted) {
            ## append to new aliases file
            print NEWALIAS $alias;
        }
    }
    close ALIAS;
    close NEWALIAS;

    if ($#deleted_lines == -1) {
        print STDERR "No matching line in $alias_file\n";
        exit(9);
    }
    ## replace old aliases file
    unless (open NEWALIAS, "$tmp_alias_file") {
        print STDERR "Could not read $tmp_alias_file\n";
        exit(10);
    }

    unless (open OLDALIAS, ">$alias_file") {
        print STDERR "Could not overwrite $alias_file\n";
        exit(11);
    }
    print OLDALIAS <NEWALIAS>;
    close OLDALIAS;
    close NEWALIAS;
    unlink $tmp_alias_file;

    ## Newaliases
    unless ($file || $virtual_domain != 0) {
        unless (system($alias_wrapper, "--domain=$domain") == 0) {
            if ($? == -1) {
                print STDERR "Failed to execute newaliases: $ERRNO\n";
            } else {
                printf STDERR "newaliases exited with status %d\n", ($? >> 8);
            }
            exit(6);
        }
    }

    # Unlock
    $lock_fh->close;
} else {
    print STDERR "Action $operation not implemented yet\n";
    exit(2);
}

exit 0;

## Check if an alias is already defined
sub already_defined {
	# pt is 'pattern type' - 0 for oridnary aliases, 1 for virtual regexp aliases
	my ($pt, @aliases) = @_;

    unless (open ALIAS, "$alias_file") {
        printf STDERR "Could not read $alias_file\n";
        exit(7);
    }

	my $left_side = '';
	my $new_left_side = '';
    while (my $alias = <ALIAS>) {
        # skip comment
        next if $alias =~ /^#/;
		if ($pt == 0) {
			$alias =~ /^([^\s:]+)[\s:]/;
			$left_side = $1;
		} else {
			$alias =~ /^([^\t ]+)[ \t]/;
			$left_side = $1;
		}
        next unless ($left_side);
        foreach (@aliases) {
			next unless ((($pt == 0) && ($_ =~ /^([^\s:]+)[\s:]/)) ||
				(($pt == 1) && ($_ =~ /^([^\t ]+)[ \t]/)));
			$new_left_side = $1;
            if ($left_side eq $new_left_side) {
                print STDERR "Alias already defined : $left_side\n";
                return 1;
            }
        }
    }

    close ALIAS;
    return 0;
}
