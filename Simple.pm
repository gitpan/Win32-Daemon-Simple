package Win32::Daemon::Simple;
use Win32;
use Win32::Console qw();
use Win32::Daemon;
use FindBin qw($Bin $Script);$Bin =~ s{/}{\\}g;
use File::Spec;
use FileHandle;
use Carp;
use Exporter;
use strict;
use vars qw(@ISA @EXPORT $VERSION);
@ISA = qw(Exporter);
@EXPORT = qw(ReadParam SaveParam Log LogNT OpenLog CloseLog CatchMessages GetMessages ServiceLoop DoEvents CMDLINE);
$VERSION = '0.1.3';

my ($svcid, $svcname, $svcversion) = ( $Script, $Script);
BEGIN {
	eval {
		my $title;
		if ($title = Win32::Console::_GetConsoleTitle()) {
			eval 'sub CMDLINE () {1}';
			if (lc($title) eq lc($^X) or lc($title) eq lc($0)) {
				eval 'sub FROMCMDLINE () {0}';
				eval '*MsgBox = \&Win32::MsgBox;';
				if (! @ARGV) {
					push @ARGV, '-help';
				}
			} else {
				eval 'sub FROMCMDLINE () {1}';
				eval 'sub MsgBox {}';
			}
		} else {
			eval 'sub CMDLINE () {0}';
			eval 'sub FROMCMDLINE () {0}';
			eval 'sub MsgBox {}';
		}
	};
}

my ($info, $params, $param_modify);

# parameters
use Win32::Registry;
{
	my $key;
	my $paramkey;
	sub ReadParam {
		my ( $param, $default) = @_;
		$key = $HKLM->Open('SYSTEM\CurrentControlSet\Services\\'.$svcid)
			unless $key;
		return $default unless $key;
		$paramkey = $key->Create('Parameters')
			unless $paramkey;
		my $value = $paramkey->GetValue($param);
		$value = $default unless defined $value;
		return $value;
	}

	sub SaveParam {
		my ( $param, $value) = @_;
		$key = $HKLM->Open('SYSTEM\CurrentControlSet\Services\\'.$svcid)
			unless $key;
		$paramkey = $key->Create('Parameters')
			unless $paramkey;
		if (!defined $value) {
print "Delete param: $param\n";
			$paramkey->DeleteValue($param);
		} elsif ($value =~ /^\d+$/) {
			$paramkey->SetValues($param, REG_DWORD, $value);
		} else{
			$value =~ s/\r?\n/\r\n/g;
			$paramkey->SetValues($param, REG_SZ, $value);
		}
	}
}

my ($logging_code,$loop_code);
# main processing
sub import {
	shift();
	my $caller_pack = caller;
	eval {
		my ($key, $val);
		while (defined ($key = shift()) and defined ($val = shift())) {
			$key = lc $key;
			if ($key eq 'service') {
				$svcid = $val;
			} elsif ($key eq 'name') {
				$svcname = $val;
			} elsif ($key eq 'version') {
				$svcversion = $val;
			} elsif ($key eq 'info') {
				$info = $val;
			} elsif ($key eq 'params') {
				$params = $val;
			} elsif ($key eq 'param_modify') {
				$param_modify = {};
				foreach my $param (keys %$val) { # hashes are case sensitive, the param should be INsensitive!
					$param_modify->{lc $param} = $val->{$param};
				}
			} else {
				croak "Unknown option '$key' passed to use Win32::Daemon::Simple!";
			}
		}
		if (! ref $info) {
			croak "Required parameter 'info' not specified";
		};

		if (! ref $params) { $params = {} };
		if (! ref $param_modify) { $param_modify = {} };
		unless (defined $params->{'LogFile'}) {
			my $logfile = $Bin . '\\' . $Script;
			$logfile =~ s/\.[^\.]+$/.log/ or $logfile .= '.log';
			$logfile =~ s{/}{\\}g;
			$params->{'LogFile'} = $logfile;
		} elsif ($params->{'LogFile'} !~ m{^\w:[\\/]}) {
			$params->{'LogFile'} = $Bin . '\\' . $params->{'LogFile'};
		}

		if (CMDLINE) {
			Win32::Console::_SetConsoleTitle( "$svcname $svcversion (in commandline mode)");
		}

		if (@ARGV) { # we've got some params !
			print "$svcname $svcversion\n";
			my $inst = 0;
			my $re = join '|', map {quotemeta $_} (keys %$params);
			my $nore = qr{^[-/]no($re)$}i;
			my $defre = qr{^[-/]DEFAULT($re)$}i;
			$re = qr{^[-/]($re)(?:=(.*))?$}si;

			foreach my $opt (@ARGV) {
				if ($opt =~ m{^[-/]install}i) {
					$info->{'name'} = $svcid;
					$info->{'display'} = $svcname unless defined $info->{'display'};
					if (! exists $info->{'path'}) {
						if ($0 !~ /\.exe$/i) {
							$info->{'path'} =  $^X;
							$info->{'parameters'} = "$Bin\\$Script"
						} else {
							$info->{'path'} = "$Bin\\$Script";
						}
					}
					Win32::Daemon::DeleteService($svcid);
					sleep(2);
					{
						my $logdir = $params->{'LogFile'};
						$logdir =~ s{[\\/][^\\/]+$}{};
						mkdir $logdir unless -d $logdir;
					}
					if( Win32::Daemon::CreateService( $info ) ) {
						foreach my $param (keys %$params) {
							SaveParam( $param, $params->{$param});
						}
						print "    Installed successfully\n    $info->{'path'} $info->{'parameters'}\n";
						MsgBox "Installed successfully\n    $info->{'path'} $info->{'parameters'}\n", MB_ICONINFORMATION, $svcname;
					} else {
						print "    Failed to install: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n";
						MsgBox "Failed to install: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n", MB_ICONERROR, $svcname;
					}
					$inst = 1;
				} elsif ($opt =~ m{^[-/]uninstall}i) {
					if( Win32::Daemon::DeleteService($svcid) ) {
						print "    Uninstalled successfully\n";
						MsgBox "Uninstalled successfully\n", MB_ICONINFORMATION, $svcname;
					} else {
						print "    Failed to uninstall: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n";
						MsgBox "Failed to uninstall: " . Win32::FormatMessage( Win32::Daemon::GetLastError() ) . "\n", MB_ICONERROR, $svcname;
					}
					$inst = 1;
				} elsif ($opt =~ m{^[-/](?:help|\?)}i) {
					my $dsc = $params->{'Description'};
					$dsc =~ s/\n/\n      /g;
					print <<"*END*";

$Script -install
  : installs the service

$Script -uninstall
  : uninstalls the service

$Script -params
  : displays the effective settings

$Script -PARAM=VALUE
  : changes the value of an option (you may specify several params at once)
      LogFile : path to the log file
      $dsc

$Script -PARAM
  : changes the value of the option to 1

$Script -noPARAM
  : changes the value of the option to 0
*END*
					if (! FROMCMDLINE) {
						print "(press ENTER to exit)\n";
						<STDIN>;
					}
					exit();
				} elsif ($opt =~ m{^[-/]params}i) {
					foreach my $param (keys %$params) {
						next if lc($param) eq 'description';
						$val = ReadParam( $param, $params->{$param});
						if ($val =~ s/\n/\n        /g) {
							print "    $param:\n        $val\n";
						} else {
							print "    $param: $val\n";
						}
					}
					if (! FROMCMDLINE) {
						print "(press ENTER to exit)\n";
						<STDIN>;
					}
					exit();
				} elsif ($opt =~ $re) {
					my ( $opt, $val) = ( lc($1), $2);
					$val = 1 unless defined $val;
					if (exists $param_modify->{lc $opt}) {
						eval {
							$val = $param_modify->{lc $opt}->($val);
							print "    $opt: $val\n";
							SaveParam( $opt, $val);
						};
						if ($@) {
							print "    $opt: $@\n";
						}
					} else {
						print "    $opt: $val\n";
						SaveParam( $opt, $val);
					}
				} elsif ($opt =~ $nore) {
					my ( $opt) = lc($1);
					my $val = 0;
					if (exists $param_modify->{lc $opt}) {
						eval {
							$val = $param_modify->{lc $opt}->($val);
							print "    $opt: $val\n";
							SaveParam( $opt, $val);
						};
						if ($@) {
							print "    $opt: $@\n";
						}
					} else {
						print "    $opt: $val\n";
						SaveParam( $opt, $val);
					}
				} elsif ($opt =~ $defre) {
					my ( $opt) = lc($1);
					my $val = undef;
					SaveParam( $opt, $val);
					print "    $opt: -DEFAULT-VALUE-\n";
				} elsif ($opt =~ m{^[-/]default$}i) {
					foreach my $param (keys %$params) {
						SaveParam( $param, $params->{$param});
						next if lc($param) eq 'description';
						my $val = $params->{$param};
						if ($val =~ s/\n/\n        /g) {
							print "    $param:\n        $val\n";
						} else {
							print "    $param: $val\n";
						}
					}
				} else {
					MsgBox "Unknown option '$opt'", MB_ICONEXCLAMATION, $svcname;
					$inst = 1;
				}
			}
			MsgBox "Changed the options", MB_ICONINFORMATION, $svcname
				unless $inst;
			exit; # if we have params
		}

		eval $logging_code; die "$@\n" if $@;
		$logging_code = '';

		Win32::Daemon::StartService();

		if (CMDLINE) {
			no warnings qw(redefine);
			eval "sub Win32::Daemon::State {&SERVICE_START_PENDING}";
		}

		while( &SERVICE_START_PENDING != Win32::Daemon::State() ) {
			sleep( 1 );
		}

		if (CMDLINE) {
			no warnings qw(redefine);
			eval "sub Win32::Daemon::State {&SERVICE_RUNNING}";
		}

		LogStart("\n$svcname ver. $svcversion started");

		Win32::Daemon::State( SERVICE_RUNNING );

		OpenLog();
		LogNT("Read params");
		{
			local $^W;
			no strict 'refs';
			my $val;
			foreach my $param (keys %$params) {
				my $sub = uc $param;
				$val = ReadParam( $param, $params->{$param});
				LogNT("\t$param: $val") unless lc($param) eq 'description';
				if ($val =~ /^\d+(?:\.\d+)?$/) { # if it looks like a number it IS a number
					$val += 0;
					eval "sub $sub () {$val}";
				} else {
					$val =~ s{(['\\])}{\\$1}g;
					eval "sub $sub () {'$val'}";
				}
				push @EXPORT, $sub;
			}
		}
		LogNT('Running');
		CloseLog();
		eval $loop_code; die "$@\n" if $@;
		$loop_code = '';

	};
	if ($@) {
		if (CMDLINE) {
			die "ERROR in use Win32::Daemon::Simple: $@\n";
		} elsif ($params->{'LogFile'}) {
			Log("ERROR in use Win32::Daemon::Simple: $@");
			exit;
		} elsif ($svcid) {
			SaveParam("ERROR", $@);
			exit;
		} else {
			exit(); # don't have a way to report the problem. The person should have tried it in commandline mode first.
		}
	} else {
		SaveParam("ERROR", undef);
	};

	Win32::Daemon::Simple->export_to_level( 1, $caller_pack, @EXPORT);
}

$loop_code = <<'-END--';
my $PrevState = SERVICE_START_PENDING;
sub SetState ($) {
	Win32::Daemon::State($_[0]);
	$PrevState = $_[0];
}

END {
	Win32::Daemon::State(SERVICE_STOPPED) unless $PrevState == SERVICE_STOPPED;
}

sub ServiceLoop {
	my $process = shift();
	my $cnt = int(INTERVAL * 60);
	my $tick_cnt = 60;
	my $state;
	while (1) {
		$state = Win32::Daemon::State();
		if ($state == SERVICE_RUNNING or $state == 0x0080) {
			# RUNNING
			if ($state == 0x0080) {
				SetState(SERVICE_RUNNING);
			}

			# Check for any outstanding commands. Pass in a non zero value
			# and it resets the Last Message to SERVICE_CONTROL_NONE.
			if ( SERVICE_CONTROL_NONE != ( my $Message = Win32::Daemon::QueryLastMessage( 1 ))) {
				if ( SERVICE_CONTROL_INTERROGATE == $Message ) {
					# Got here if the Service Control Manager is requesting
					# the current state of the service. This can happen for
					# a variety of reasons. Report the last state we set.
					Win32::Daemon::State( $PrevState );
				} elsif ( SERVICE_CONTROL_SHUTDOWN == $Message ) {
					# Yikes! The system is shutting down. We had better clean up
					# and stop.
					# Tell the SCM that we are preparing to shutdown and that we expect
					# it to take 25 seconds (so don't terminate us for at least 25 seconds)...
					Win32::Daemon::State( SERVICE_STOP_PENDING, 25000 );
				} else {
					# Got an unhandled control message. Set the state to
					# whatever the previous state was.
					Log("Unhandled service message: $Message");
					Win32::Daemon::State( $PrevState );
				}
			}

			if (--$cnt == 0) {
				$cnt = int(INTERVAL * 60);
				eval {$process->()};
				if ($@) {
					Log("ERROR: $@");
					LogNT;
				}
			}
			if (TICK and (--$tick_cnt == 0)) {
				Log('tick') ;
				$tick_cnt = 60;
			}
			sleep 1;
			# /RUNNING
		} elsif ($state == SERVICE_PAUSE_PENDING) {
			SetState(SERVICE_PAUSED);
			Log("Paused");
		} elsif ($state == SERVICE_PAUSED) {
			sleep 10;
		} elsif ($state == SERVICE_CONTINUE_PENDING) {
			SetState(SERVICE_RUNNING);
			Log("Continue");
		} elsif ($state == SERVICE_STOP_PENDING or $state == SERVICE_STOPPED) {
			SetState(SERVICE_STOPPED);
			Log("Asked to stop");
			last;
		} else {
			Log("Unexpected state : $state");
			last;
		}
	}

	Win32::Daemon::StopService();
}

sub DoHandler {
	my ($handler, $do) = @_;
	if (defined $handler) {
		if (ref $handler) {
			if ($handler->(1)) {
				$do->();
				return 1;
			}
		} elsif ($handler) {
			$do->();
			return 1;
		}
		return;
	}
	$do->();
	return 1;
}

sub DoEvents { # (\&PauseProc, \&UnpauseProc, \&StopProc)
	my $state = Win32::Daemon::State();
	if ($state == SERVICE_RUNNING or $state == 0x0080) {
		# RUNNING
		if ($state == 0x0080) {
			SetState(SERVICE_RUNNING);
		}

		# Check for any outstanding commands. Pass in a non zero value
		# and it resets the Last Message to SERVICE_CONTROL_NONE.
		if ( SERVICE_CONTROL_NONE != ( my $Message = Win32::Daemon::QueryLastMessage( 1 ))) {
			if ( SERVICE_CONTROL_INTERROGATE == $Message ) {
				# Got here if the Service Control Manager is requesting
				# the current state of the service. This can happen for
				# a variety of reasons. Report the last state we set.
				Win32::Daemon::State( $PrevState );
			} elsif ( SERVICE_CONTROL_SHUTDOWN == $Message ) {
				# Yikes! The system is shutting down. We had better clean up
				# and stop.
				# Tell the SCM that we are preparing to shutdown and that we expect
				# it to take 25 seconds (so don't terminate us for at least 25 seconds)...
				Win32::Daemon::State( SERVICE_STOP_PENDING, 25000 );
				Log("Asked to stop");
				DoHandler( $_[2], sub {Win32::Daemon::StopService();Log("Going down");exit;});
			} else {
				# Got an unhandled control message. Set the state to
				# whatever the previous state was.
				Log("Unhandled service message: $Message");
				Win32::Daemon::State( $PrevState );
			}
		}
		return SERVICE_RUNNING;
		# /RUNNING
	} elsif ($state == SERVICE_PAUSE_PENDING) {
		if (DoHandler( $_[0], sub {SetState(SERVICE_PAUSED);Log("Paused")})) {
			return Pause(@_[1,2]);
		} else {
			return SERVICE_PAUSE_PENDING;
		}
	} elsif ($state == SERVICE_PAUSED) {
		return Pause(@_[1,2]);
	} elsif ($state == SERVICE_CONTINUE_PENDING) {
		SetState(SERVICE_RUNNING);
		Log("Continue");
		$_[1]->() if (defined $_[1] and ref $_[1] eq 'CODE');
	} elsif ($state == SERVICE_STOP_PENDING or $state == SERVICE_STOPPED) {
		Log("Asked to stop");
		DoHandler( $_[2], sub {Win32::Daemon::StopService();Log("Going down");exit;});
		return SERVICE_STOP_PENDING;
	} else {
		Log("Unexpected state : $state");
		return $state
	}
}

sub Pause {
	my $state;
	while (1) {
		sleep(5);
		$state = Win32::Daemon::State();
		next if $state == SERVICE_PAUSED;

		if ($state == SERVICE_STOP_PENDING or $state == SERVICE_STOPPED) {
			Log("Asked to stop");
			DoHandler( $_[1], sub {Win32::Daemon::StopService();Log("Going down");exit;});
			return SERVICE_STOP_PENDING;
		} else {
			# unpausing
			Log("Continue");
			$_[0]->() if (defined $_[1] and ref $_[1] eq 'CODE');
			SetState(SERVICE_RUNNING);
			return SERVICE_RUNNING
		}
	}
}

-END--

# logging
$logging_code = <<'-END--';
{
	my $logfile;
	my $catchmessages = 0;
	my $messages = '';
	my $LOG = new FileHandle;
	sub LogStart {
		$logfile = ReadParam('LogFile', $params->{'LogFile'})
			unless $logfile;
		open $LOG, ">> $logfile";
		print $LOG @_, " at ",scalar(localtime()),"\n";
		print STDOUT @_,"\n" if CMDLINE;
		close $LOG;
	}
	sub Log {
		my $had_to_open = 0;
		if (! $LOG->opened()) {
			$had_to_open = 1;
			unshift @_, "$svcname $svcversion\n"
				unless -e $logfile;
			open $LOG, ">> $logfile";
		}
		print $LOG @_, " at ",scalar(localtime()),"\n";
		$messages .= join '', @_,"\n"
			if $catchmessages;
		print STDOUT @_,"\n"
			if CMDLINE;
		close $LOG
			if $had_to_open;
	}
	sub LogNT {
		my $had_to_open = 0;
		if (! $LOG->opened()) {
			$had_to_open = 1;
			unshift @_, "$svcname $svcversion\n"
				unless -e $logfile;
			open $LOG, ">> $logfile";
		}
		print $LOG @_,"\n";
		$messages .= join '', @_,"\n"
			if $catchmessages;
		print STDOUT @_,"\n"
			if CMDLINE;
		close $LOG
			if $had_to_open;
	}
	sub OpenLog () {
		if (! $LOG->opened()) {
			$logfile = ReadParam('LogFile', $params->{'LogFile'})
				unless $logfile;
			my $existed = -e $logfile;
			open $LOG, ">> $logfile";
			print $LOG "$svcname $svcversion\n"
				unless $existed;
		}
	}
	sub CloseLog () {
		close $LOG if $LOG->opened();
	}
	sub CatchMessages {
		$catchmessages = shift();
		$messages = '';
	}
	sub GetMessages {
		my $msg = $messages;
		$messages = '';
		return $msg;
	}
}
-END--


1;

__END__
=head1 NAME

Win32::Daemon::Simple - framework for Windows services

=head1 SYNOPSIS

	use FindBin qw($Bin $Script);
	use File::Spec;
	use Win32::Daemon::Simple
		Service => 'SERVICENAME',
		Name => 'SERVICE NAME',
		Version => 'x.x',
		Info => {
			display =>  'SERVICEDISPLAYNAME',
			description => 'SERVICEDESCRIPTION',
			user    =>  '',
			pwd     =>  '',
			interactive => 0,
	#		path    =>  $^X,
	#		parameters => "$Bin\\$Script",
		},
		Params => {
			Tick => 0,
			Talkative => 0,
			Interval => 10, # minutes
			LogFile => "$Bin\\Import",
			# ...
			Description => <<'*END*',
	Tick : (0/1) controls whether the service writes a "tick" message to
	  the log once a minute if there's nothing to do
	Talkative : controls the amount of logging information
	Interval : how often does the service look for new or modified files
	  (in minutes)
	LogFile : the path to the log file
	...
	*END*
		},
		param_modify => {
			LogFile => sub {File::Spec->rel2abs($_[0])},
			Interval => sub {no warnings;my $interval = 0+$_[0]; die "The interval must be a positive number!\n" unless $interval > 0;return $interval},
			Tick => sub {return ($_[0] ? 1 : 0)},
		};

	# initialization

	ServiceLoop(\&doTheJob);

	# cleanup

	Log("Going down");
	exit;

	# definition of doTheJob()
	# You may want to call DoEvents() within the doTheJob() at places where it
	# would be safe to pause or stop the service if the processing takes a lot of time.
	# Eg. DoEvents( \&close_db, \&open_db, sub {close_db(); cleanup();1})

=head1 DESCRIPTION

This module will take care of the instalation/deinstalation, reading, storing and modifying parameters,
service loop with status processing and logging. It's a simple to use framework for services that need
to wake up from time to time and do its job and otherwise should just poll the service status and sleep
as well as services that watch something and poll the Service Manager requests from time to time.

You may leave the looping to the module and only write a procedure that will be called in the specified
intervals or loop yourself and allow the module to process the requests when it fits you.

This module should allow you to create your services in a simple and consistent way. You just provide the
service name and other settings and the actuall processing, the service related stuff and commandline
parameters are taken care off already.

=head2 EXPORT

=head3 ServiceLoop

	ServiceLoop( \&processing)

Starts the event processing loop. The subroutine you pass will be called in the specified
intervals.

In the loop the module tests the service status and processes requests from Service Manager, ticks
(writes "Tick at $TimeStamp" messages once a minute if the Tick parameter is set) and calls your callback
if the interval is out. Then it will sleep(1).

=head3 DoEvents

	DoEvents()
	DoEvents( $PauseProc, $UnPauseProc, $StopProc)

You may call this procedure at any time to process the requests from the Service Manager.
The first parameter specifies what is to be done if the service is to be paused, the second
when it has to continue and the third when it's asked to stop.

If $PauseProc is:

	undef : the service is automaticaly paused,
		DoEvents() returns after the Service Manager asks it to continue
	not a code ref and true : the service is automaticaly paused,
		DoEvents() returns after the Service Manager asks it to continue
	not a code ref and false : the service is not paused,
		DoEvents() returns SERVICE_PAUSE_PENDING immediately.
	a code reference : the procedure is executed. If it returns true
		the service is paused and DoEvents() returns after the service
		manager asks the service to continue, if it returns false DoEvents()
		returns SERVICE_PAUSE_PENDING.

If $UnpauseProc is:

	a code reference : the procedure will be executed when the service returns from
		the paused state.
	anything else : nothing will be done

If $StopProc is:

	undef : the service is automaticaly stopped and
		the process exits
	not a code ref and true : the service is automaticaly stopped and
		the process exits
	not a code ref and false : the service is not stopped,
		DoEvents() returns SERVICE_STOP_PENDING immediately.
	a code reference : the procedure is executed. If it returns true
		the service is stopped and the process exits, if it returns false DoEvents()
		returns SERVICE_PAUSE_PENDING.

=head3 Pause

	Pause()
	Pause($UnPauseProc, $StopProc)

If the DoEvents() returned SERVICE_STOP_PENDING you should do whatever you need
to get the service to a pausable state (close open database connections etc.) and
call this procedure. The meanings of the parameters is the same as for DoEvents().

=head3 Log

Writes the parameters to the log file (and in commandline mode also to the console).
Appends " at $TimeStamp\n" to the message.

=head3 LogNT

Writes the parameters to the log file (and in command line mode also to the console).
Only appends the newline.

=head3 ReadParam

	$value = ReadParam( $paramname, $default);

Reads the value of a parameter stored in
HKLM\SYSTEM\CurrentControlSet\Services\SERVICENAME\Parameters
If there is no value with that name returns the $default.

=head3 SaveParam

	SaveParam( $paramname, $value);

Stores the new value of the parameter in
HKLM\SYSTEM\CurrentControlSet\Services\SERVICENAME\Parameters.

=head3 CatchMessages

	CatchMessages( $boolean);

Turns on or off capturing of messages passed to Log() or LogNT(). Clears the buffer.

=head3 GetMessages

	$messages = GetMessages();

Returns the messages captured since CatchMessages(1) or last GetMessages(). Clears the buffer.

These two functions are handy if you want to mail the result of a task. You just CatchMessages(1) when you start
the task and GetMessages() and CatchMessages(0) when you are done.

=head3 CMDLINE

Constant. If set to 1 the service is running in the command line mode, otherwise set to 0.

=head3 PARAMETERNAME

For each parameter specified in the C<params=>{...}> option the module reads
the actual value from the registry (using the value from the C<params=>{...}> option
as a default) and defines a constant named C<uc($parametername)>.

=head2 Service parameters

The service created using this module will accept the following commandline parameters:

=head3 -install

Installs the service and stores the default values of the parameters to the registry into
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ServiceName\Parameters

If you get an error like

	Failed to install: The specified service has been marked for deletion.

or

	Failed to install: The specified service already exists.

close the Services window and/or the regedit and try again!

=head3 -uninstall

Uninstalls the service.

=head3 -params

Prints the actual values of all the parameters of the service.

=head3 -help

Prints the name and version of the service and the list of options.
If the parameters=>{} option contained a Description, then the Description is printed as well.

=head3 -default

Sets all parameters to their default values.

=head3 -PARAM

Sets the value of PARAM to 1. The parameter names are case insensitive.

=head3 -noPARAM

Sets the value of PARAM to 1. The parameter names are case insensitive.

=head3 -PARAM=value

Sets the value of PARAM to value. The parameter names are case insensitive.

You may validate and/or modify the value with a handler specified in the
param_modify=>{} option. If the handler die()s the value will NOT be changed
and the error message will be printed to the screen.

=head3 -defaultPARAM

Deletes the parameter from registry, therefore the default value of that parameter
will be used each time the service starts.

=head3 Comments

The scripts using this module are sensitive to the way they were started.

If you start them with a parameter they process that parameter as explained abovet.
Then if you started them from the Run dialog or by doubleclicking they print
(press ENTER to continue) and wait for the user to press enter, if you started them from
the command prompt they exit immediately

If they are started without parameters by the Service Manager they register with
the Manager and start your code, if they are started without parameters from command prompt
they start working in a command line mode (all info is printed to the screen as well as to the log file)
and if they are started by doubleclicking on the script they show the -help screen.

=head1 AUTHOR

 Jenda@Krynicky.cz
 http://Jenda.Krynicky.cz

=head1 SEE ALSO

L<Win32::Daemon>.

=cut
