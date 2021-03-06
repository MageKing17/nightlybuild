package Git;

# Git Nightlybuild Plugin 2.3
# 2.3 - Fix issue where the branch would have to be reset when a build failed by utilizing the remote branch more often.
# 2.2 - Add some more types of revision for use with nightlies, fix an archiving bug on Windows.
# 2.1 - Generate the next build revision instead of passing it to the script.
# 2.0 - Support for release building as well as nightly building
# 1.0 - Initial release

use strict;
use warnings;

use File::Basename;
use lib dirname (__FILE__);
use File::Spec::Functions;
use Config::Tiny;
require Vcs;
use base 'Vcs';

my $CONFIG = Config::Tiny->new();
$CONFIG = Config::Tiny->read(dirname (__FILE__) . "/Git.conf"); # Read in the plugin config info
if(!(Config::Tiny->errstr() eq "")) { die "Could not read config file, did you copy the sample to Git.conf and edit it?\n"; }

sub new
{
	my $type = shift;
	my %parm = @_;
	my $this = Vcs->new(%parm);  # Create an anonymous hash, and #self points to it.

	$this->{gitremotecmd} = 'git --git-dir="' . catfile($this->{source_path}, ".git") . '" --work-tree="' . $this->{source_path} . '"';
	$this->{nightly_branch} = $CONFIG->{general}->{nightly_branch};
	$this->{nightly_branch} =~ s/##BRANCH##/$CONFIG->{general}->{track_branch}/;
	$this->{nightly_branch} =~ s/##OS##/$this->{'OS'}/;

	bless $this, $type;       # Connect the hash to the package Git.
	return $this;     # Return the reference to the hash.
}

sub getrevision
{
	my ($class) = @_;
	my $createcommand;
	my $command;
	my $output;
	my $fetchcommand = $class->{gitremotecmd} . " fetch " . $CONFIG->{general}->{track_remote};
	`$fetchcommand`;
	# See if nightly_branch exists
	system($class->{gitremotecmd} . " show-ref --verify --quiet refs/heads/" . $class->{nightly_branch});
	if($? >> 8 != 0)
	{
		# Branch does not exist yet.  Create a new one based on the remote branch,
		# or on [TRACKING_REMOTE]/master~ if it doesn't exist yet.
		$createcommand = $class->{gitremotecmd} . " update-ref refs/heads/" . $class->{nightly_branch} . " " . $CONFIG->{general}->{track_remote} . "/";
		system($class->{gitremotecmd} . " show-ref --verify --quiet refs/remotes/" . $CONFIG->{general}->{track_remote} . "/" . $class->{nightly_branch});
		if($? >> 8 != 0)
		{
			# Remote branch is non-existent too.
			$createcommand = $createcommand . $CONFIG->{general}->{track_branch} . "~";
		}
		else
		{
			$createcommand = $createcommand . $class->{nightly_branch};
		}
		`$createcommand 2>&1`;
	}
	$command = $class->{gitremotecmd} . " rev-parse " . $CONFIG->{general}->{track_remote} . "/" . $class->{nightly_branch};
	$output = `$command 2>&1`;
	$output =~ s/^\s+|\s+$//g;

	return $output;
}

sub get_next_release_revision
{
	my ($class) = @_;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
	my @months = qw(01 02 03 04 05 06 07 08 09 10 11 12);
	my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
	$year += 1900;
	$mon = $months[$mon];
	if($mday < 10)
	{
		$mday = "0" . $mday;
	}
	return $year . $mon . $mday;
}

sub createbranch
{
	my ($class, $revision, $version) = @_;
	my $cmd = $class->{gitremotecmd} . " update-ref refs/heads/" . Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format}) . " " . $revision;
	print $cmd . "\n";
	`$cmd`;
	$cmd = $class->{gitremotecmd} . " push " . $CONFIG->{general}->{track_remote} . " " . Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format});
	print $cmd . "\n";
	`$cmd`;
	$cmd = $class->{gitremotecmd} . " branch -u " . $CONFIG->{general}->{track_remote} . "/" . Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format}) . " " . Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format});
	print $cmd . "\n";
	`$cmd`;
}

sub checkout_update
{
	my ($class, $version) = @_;
	my $cmd = $class->{gitremotecmd} . " fetch " . $CONFIG->{general}->{track_remote};
	print $cmd . "\n";
	`$cmd`;
	$cmd = $class->{gitremotecmd} . " checkout " . Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format});
	print $cmd . "\n";
	`$cmd`;
	$cmd = $class->{gitremotecmd} . " pull";
	print $cmd . "\n";
	`$cmd`;

	return $class->{source_path};
}

sub commit_versions
{
	my ($class, $checkout_path, $version, $subversion) = @_;
	my $cmd;
	my $fullversion = $version . ($subversion ? " " . $subversion : "");

	$cmd = $class->{gitremotecmd} . " commit -am 'Automated " . $fullversion . " versioning commit'";
	print $cmd . "\n";
	`$cmd`;
	$cmd = $class->{gitremotecmd} . " push " . $CONFIG->{general}->{track_remote} . " " . Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format});
	print $cmd . "\n";
	`$cmd`;
}

sub update
{
	my ($class) = @_;
	my $command;

	if($class->{stoprevision})
	{
		#Don't use the tracking branch, stop at the specified revision
		$command = $class->{gitremotecmd} . " rev-parse " . $class->{stoprevision};
	}
	else
	{
		#Compare track_branch hash to nightly_branch hash
		$command = $class->{gitremotecmd} . " rev-parse " . $CONFIG->{general}->{track_remote} . "/" . $CONFIG->{general}->{track_branch};
	}
	$class->{revision} = `$command 2>&1`;
	$class->{revision} =~ s/^\s+|\s+$//g;
	if($class->{revision} eq $class->{oldrevision})
	{
		# Nightly is up to date.
		return 0;
	}
	else
	{
		# Update the local branch hash to the track branch hash.
		$class->{buildrevision} = substr($class->{revision}, 0, 7);
		$class->{displayrevision} = $class->{buildrevision};
		$class->{ident} = $class->{buildrevision};
		$class->{fsrevision} = $class->get_next_release_revision();
	}

	return 1;
}

sub export
{
	my $class = shift;
	my $source;
	my $exportcommand;
	my $tarpath;
	my $export_branch;

	unless($source = shift)
	{
		my $i = 0;
		$source = $class->{source_path};

		do {
			$class->{exportpath} = $source . "_" . $i++;
		} while (-d $class->{exportpath});

		$export_branch = $CONFIG->{general}->{track_branch};
	}
	else
	{
		my $version = shift;
		$class->{exportpath} = catfile(dirname($source), Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format}));
		if(my $subversion = shift)
		{
			$class->{exportpath} .= "_" . $subversion;
		}

		$export_branch = Vcs::get_dirbranch($version, $CONFIG->{general}->{branch_format});
	}

	print "Going to export " . $source . " to directory " . $class->{exportpath} . "\n";

	mkdir($class->{exportpath});

	$tarpath = $class->{exportpath};
	# Hack for tar on Windows, it needs Unix style path separators.
	$tarpath =~ s/\\/\//g;

	$exportcommand = $class->{gitremotecmd} . " archive --format=tar " . $CONFIG->{general}->{track_remote} . "/" . $export_branch . " | tar -C " . $tarpath . " -xf -";
	system($exportcommand);
	if($? >> 8 == 0)
	{
		# Export command returned success (0).
		return 1;
	}
	else
	{
		# Export command returned non-zero return value.
		return 0;
	}
}

sub get_log
{
	my ($class) = @_;
	my $logcommand = $class->{gitremotecmd} . ' log "' . $class->{revision} . '" "^' . $class->{oldrevision} . '" --no-merges';
	if($CONFIG->{general}->{log_pretty})
	{
		$logcommand = $logcommand . " --stat --pretty=" . $CONFIG->{general}->{log_pretty};
	}
	return `$logcommand`;
}

sub finalize
{
	my ($class) = @_;
	# Update the local branch hash to the track branch hash.
	my $command = $class->{gitremotecmd} . " update-ref refs/heads/" . $class->{nightly_branch} . " " . $class->{revision};
	`$command 2>&1`;
	# Git needs to update the remote branch and push it up.
	$command = $class->{gitremotecmd} . " push " . $CONFIG->{general}->{track_remote} . " " . $class->{nightly_branch};
	`$command 2>&1`;
	$command = $class->{gitremotecmd} . " branch --set-upstream " . $class->{nightly_branch} . " " . $CONFIG->{general}->{track_remote} . "/" . $class->{nightly_branch};
	`$command 2>&1`;
}

1;
