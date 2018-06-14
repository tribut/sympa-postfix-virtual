#!/usr/bin/perl
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

use lib split(/:/, $ENV{SYMPALIB} || ''), '/usr/share/sympa/lib';
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
        'name'   => $listname,
    },
    'robot'             => $domain,
    'default_domain'    => $default_domain,
    'is_default_domain' => ($domain eq $default_domain),
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
    if (already_defined(@aliases)) {
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
    unless ($file) {
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
        $left_side = $1 if ($alias =~ /^([^\s:]+)[\s:]/);

        my $to_be_deleted = 0;
        foreach my $new_alias (@aliases) {
            next unless ($new_alias =~ /^([^\s:]+)[\s:]/);
            my $new_left_side = $1;

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
    unless ($file) {
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
    my @aliases = @_;

    unless (open ALIAS, "$alias_file") {
        printf STDERR "Could not read $alias_file\n";
        exit(7);
    }

    while (my $alias = <ALIAS>) {
        # skip comment
        next if $alias =~ /^#/;
        $alias =~ /^([^\s:]+)[\s:]/;
        my $left_side = $1;
        next unless ($left_side);
        foreach (@aliases) {
            next unless ($_ =~ /^([^\s:]+)[\s:]/);
            my $new_left_side = $1;
            if ($left_side eq $new_left_side) {
                print STDERR "Alias already defined : $left_side\n";
                return 1;
            }
        }
    }

    close ALIAS;
    return 0;
}

__END__

=encoding utf-8

=head1 NAME

alias_manager, alias_manager.pl - Manage Sympa Aliases

=head1 SYNOPSIS

S<B<alias_manager.pl> B<add> | B<del> I<listname> I<domain>>

=head1 DESCRIPTION

Alias_manager is a program that helps in installing aliases for newly
created lists and deleting aliases for closed lists. 

It is called by
L<wwsympa.fcgi(8)> or L<sympa.pl(8)> via the I<aliaswrapper>.
Alias management is performed only if it was setup in F</etc/sympa/sympa/sympa.conf>
(C<sendmail_aliases> configuration parameter).

Administrators using MTA functionalities to manage aliases (ie
virtual_regexp and transport_regexp with postfix) can disable alias
management by setting
C<sendmail_aliases> configuration parameter to B<none>.

=head1 OPTIONS

=over 4

=item B<add> I<listname> I<domain>

Add the set of aliases for the mailing list I<listname> in the
domain I<domain>.

=item B<del> I<listname> I<domain>

Remove the set of aliases for the mailing list I<listname> in the
domain I<domain>.

=back

=head1 FILES

F</etc/mail/sympa/aliases> sendmail aliases file.

=head1 DOCUMENTATION

The full documentation in HTML and PDF formats can be
found in L<http://www.sympa.org/manual/>. 

The mailing lists (with web archives) can be accessed at
http://listes.renater.fr/sympa/lists/informatique/sympa.

=head1 HISTORY

This program was originally written by:

=over 4

=item Serge Aumont

ComitE<233> RE<233>seau des UniversitE<233>s

=item Olivier SalaE<252>n

ComitE<233> RE<233>seau des UniversitE<233>s

=back

This manual page was initially written by
JE<233>rE<244>me Marant <jerome.marant@IDEALX.org>
for the Debian GNU/Linux system.

=head1 LICENSE

You may distribute this software under the terms of the GNU General
Public License Version 2.  For more details see F<README> file.

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.1 or
any later version published by the Free Software Foundation; with no
Invariant Sections, no Front-Cover Texts and no Back-Cover Texts.  A
copy of the license can be found under
L<http://www.gnu.org/licenses/fdl.html>.

=head1 BUGS

Report bugs to Sympa bug tracker.
See L<http://www.sympa.org/tracking>.

=head1 SEE ALSO

L<sympa(1)>, L<sympa_msg(8)>, L<sendmail(8)>, L<wwsympa(8)>.

=cut
