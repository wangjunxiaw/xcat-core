# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#egan@us.ibm.com
#modified by jbjohnso@us.ibm.com
#(C)IBM Corp

$xcat_plugins{ipmi}="this";
package xCAT_plugin::ipmi;

use Storable qw(store_fd retrieve_fd thaw freeze);
use xCAT::Utils;
use Thread qw(yield);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
	ipmiinit
	ipmicmd
);

sub handled_commands {
  return {
    rpower => 'nodehm:power,mgt',
    rspconfig => 'nodehm:mgt',
    rvitals => 'nodehm:vitals,mgt',
    rinv => 'nodehm:inv,mgt',
    rsetboot => 'nodehm:mgt',
    rbeacon => 'nodehm:beacon,mgt',
    reventlog => 'nodehm:eventlog,mgt',
  }
}
my %usage = (
    "rpower" => "Usage: rpower <noderange> [on|off|reset|stat|boot]",
    "rbeacon" => "Usage: rbeacon <noderange> [on|off|stat]",
    "rvitals" => "Usage: rvitals <noderange> [all|temp|wattage|voltage|fanspeed|power|leds]",
    "reventlog" => "Usage: reventlog <noderange> [all|clear|<number of entries to retrieve>]",
    "rinv" => "Usage: rinv <noderange> [all|model|serial|vpd|mprom|deviceid|uuid]",
    "rsetboot" => "Usage: rsetboot <noderange> [net|hd|cd|def|stat]"
);
    

    
use strict;
use Data::Dumper;
use POSIX "WNOHANG";
use IO::Handle;
use IO::Socket;
use IO::Select;
use Class::Struct;
use Digest::MD5 qw(md5);
use POSIX qw(WNOHANG mkfifo strftime);
use Fcntl qw(:flock);

#local to module
my @rmcp = (0x06,0x00,0xff,0x07);
my $auth;
my $rssa = 0x20;
my $rqsa = 0x81;
my $seqlun = 0x00;
my @session_id = (0,0,0,0);
my @challenge = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
my @seqnum = (0,0,0,0);
my $userid;
my $passwd;
my $timeout;
my $port;
my $debug;
my $ndebug = 0;
my $sock;
my @user;
my @pass;
my $channel_number;
my %sdr_hash;
my %fru_hash;
my $ipmiv2=0;
my $authoffset=0;
my $enable_cache="yes";
my $cache_dir = "/var/cache/xcat";
#my $ibmledtab = $ENV{XCATROOT}."/lib/GUMI/ibmleds.tab";
use xCAT::data::ibmleds;
use xCAT::data::ipmigenericevents;
use xCAT::data::ipmisensorevents;
my $cache_version = 1;

my %codes = (
	0x00 => "Command Completed Normal",
	0xC0 => "Node busy, command could not be processed",
	0xC1 => "Invalid command",
	0xC2 => "Command invalid for given LUN",
	0xC3 => "Timeout while processing command, response unavailable",
	0xC4 => "Out of space, could not execute command",
	0xC5 => "Reservation canceled or invalid reservation ID",
	0xC6 => "Request data truncated",
	0xC7 => "Request data length invalid",
	0xC8 => "Request data field length limit exceeded",
	0xC9 => "Parameter out of range",
	0xCA => "Cannot return number of requested data bytes",
	0xCB => "Requested Sensor, data, or record not present",
	0xCB => "Not present",
	0xCC => "Invalid data field in Request",
	0xCD => "Command illegal for specified sensor or record type",
	0xCE => "Command response could not be provided",
	0xCF => "Cannot execute duplicated request",
	0xD0 => "Command reqponse could not be provided. SDR Repository in update mode",
	0xD1 => "Command response could not be provided. Device in firmware update mode",
	0xD2 => "Command response could not be provided. BMC initialization or initialization agent in progress",
	0xD3 => "Destination unavailable",
	0xD4 => "Insufficient privilege level",
	0xD5 => "Command or request parameter(s) not supported in present state",
	0xFF => "Unspecified error",
);

my %units = (
	0 => "", #"unspecified",
	1 => "C",
	2 => "F",
	3 => "K",
	4 => "Volts",
	5 => "Amps",
	6 => "Watts",
	7 => "Joules",
	8 => "Coulombs",
	9 => "VA",
	10 => "Nits",
	11 => "lumen",
	12 => "lux",
	13 => "Candela",
	14 => "kPa",
	15 => "PSI",
	16 => "Newton",
	17 => "CFM",
	18 => "RPM",
	19 => "Hz",
	20 => "microsecond",
	21 => "millisecond",
	22 => "second",
	23 => "minute",
	24 => "hour",
	25 => "day",
	26 => "week",
	27 => "mil",
	28 => "inches",
	29 => "feet",
	30 => "cu in",
	31 => "cu feet",
	32 => "mm",
	33 => "cm",
	34 => "m",
	35 => "cu cm",
	36 => "cu m",
	37 => "liters",
	38 => "fluid ounce",
	39 => "radians",
	40 => "steradians",
	41 => "revolutions",
	42 => "cycles",
	43 => "gravities",
	44 => "ounce",
	45 => "pound",
	46 => "ft-lb",
	47 => "oz-in",
	48 => "gauss",
	49 => "gilberts",
	50 => "henry",
	51 => "millihenry",
	52 => "farad",
	53 => "microfarad",
	54 => "ohms",
	55 => "siemens",
	56 => "mole",
	57 => "becquerel",
	58 => "PPM",
	59 => "reserved",
	60 => "Decibels",
	61 => "DbA",
	62 => "DbC",
	63 => "gray",
	64 => "sievert",
	65 => "color temp deg K",
	66 => "bit",
	67 => "kilobit",
	68 => "megabit",
	69 => "gigabit",
	70 => "byte",
	71 => "kilobyte",
	72 => "megabyte",
	73 => "gigabyte",
	74 => "word",
	75 => "dword",
	76 => "qword",
	77 => "line",
	78 => "hit",
	79 => "miss",
	80 => "retry",
	81 => "reset",
	82 => "overflow",
	83 => "underrun",
	84 => "collision",
	85 => "packets",
	86 => "messages",
	87 => "characters",
	88 => "error",
	89 => "correctable error",
	90 => "uncorrectable error",
);

my %chassis_types = (
	0 => "Unspecified",
	1 => "Other",
	2 => "Unknown",
	3 => "Desktop",
	4 => "Low Profile Desktop",
	5 => "Pizza Box",
	6 => "Mini Tower",
	7 => "Tower",
	8 => "Portable",
	9 => "LapTop",
	10 => "Notebook",
	11 => "Hand Held",
	12 => "Docking Station",
	13 => "All in One",
	14 => "Sub Notebook",
	15 => "Space-saving",
	16 => "Lunch Box",
	17 => "Main Server Chassis",
	18 => "Expansion Chassis",
	19 => "SubChassis",
	20 => "Bus Expansion Chassis",
	21 => "Peripheral Chassis",
	22 => "RAID Chassis",
	23 => "Rack Mount Chassis",
);

my %MFG_ID = (
	2 => "IBM",
	343 => "Intel",
);

my %PROD_ID = (
	"2:34869" => "e325",
	"2:3" => "x346",
	"2:4" => "x336",
	"343:258" => "Tiger 2",
	"343:256" => "Tiger 4",
);

my $localtrys = 3;
my $localdebug = 0;

struct SDR_rep_info => {
	version		=> '$',
	rec_count	=> '$',
	resv_sdr	=> '$',
};

struct SDR => {
	rec_type			=> '$',
	sensor_owner_id		=> '$',
	sensor_owner_lun	=> '$',
	sensor_number		=> '$',
	entity_id			=> '$',
	entity_instance		=> '$',
	sensor_init			=> '$',
	sensor_cap			=> '$',
	sensor_type			=> '$',
	event_type_code		=> '$',
	ass_event_mask		=> '@',
	deass_event_mask	=> '@',
	dis_read_mask		=> '@',
	sensor_units_1		=> '$',
	sensor_units_2		=> '$',
	sensor_units_3		=> '$',
	linearization		=> '$',
	M					=> '$',
	tolerance			=> '$',
	B					=> '$',
	accuracy			=> '$',
	accuracy_exp		=> '$',
	R_exp				=> '$',
	B_exp				=> '$',
	analog_char_flag	=> '$',
	nominal_reading		=> '$',
	normal_max			=> '$',
	normal_min			=> '$',
	sensor_max_read		=> '$',
	sensor_min_read		=> '$',
	upper_nr_threshold	=> '$',
	upper_crit_thres	=> '$',
	upper_ncrit_thres	=> '$',
	lower_nr_threshold	=> '$',
	lower_crit_thres	=> '$',
	lower_ncrit_thres	=> '$',
	pos_threshold		=> '$',
	neg_threshold		=> '$',
	id_string_type		=> '$',
	id_string		=> '$',
	#LED id
	led_id		=> '$',
};

struct FRU => {
	rec_type			=> '$',
	desc				=> '$',
	value				=> '$',
};

sub translate_sensor {
   my $reading = shift;
   my $sdr = shift;
   my $unitdesc;
   my $value;
   my $lformat;
   my $per;
   $unitdesc = $units{$sdr->sensor_units_2};
   $value = (($sdr->M * $reading) + ($sdr->B * (10**$sdr->B_exp))) * (10**$sdr->R_exp);
   if($sdr->linearization == 0) {
      $reading = $value;
      if($value == int($value)) {
         $lformat = "%-30s%8d%-20s";
      } else {
         $lformat = "%-30s%8.3f%-20s";
      }
   } elsif($sdr->linearization == 7) {
      if($value > 0) {
         $reading = 1/$value;
      } else {
         $reading = 0;
      }
      $lformat = "%-30s%8d %-20s";
   } else {
      $reading = "RAW($sdr->linearization) $reading";
   }
   if($sdr->sensor_units_1 & 1) {
      $per = "% ";
   } else {
      $per = " ";
   }
   my $numformat = ($sdr->sensor_units_1 & 0b11000000) >> 6;
   if ($numformat) {
     if ($numformat eq 0b11)  {
        #Not sure what to do.. leave it alone for now
     } else {
        if ($reading & 0b10000000) {
          if ($numformat eq 0b01) {
             $reading = 0-((~($reading&0b01111111))&0b1111111);
          } elsif ($numformat eq 0b10) {
             $reading = 0-(((~($reading&0b01111111))&0b1111111)+1);
          }
        }
     }
   }
   if($unitdesc eq "Watts") {
      my $f = ($reading * 3.413);
      $unitdesc = "Watts (" . int($f + .5) . " BTUs/hr)";
      #$f = ($reading * 0.00134);
      #$unitdesc .= " $f horsepower)";
   }
   if($unitdesc eq "C") {
      my $f = ($reading * 9/5) + 32;
      $unitdesc = "C (" . int($f + .5) . " F)";
   }
   if($unitdesc eq "F") {
      my $c = ($reading - 32) * 5/9;
      $unitdesc = "F (" . int($c + .5) . " C)";
   }
   return "$reading $unitdesc";
}


sub ipmiinit {
	my $ipmimaxp = 80;
	my $ipmitimeout = 3;
	my $ipmitrys = 3;
	my $ipmiuser = 'USERID';
	my $ipmipass = 'PASSW0RD';
	my $tmp;

	
	my $table = xCAT::Table->new('site');
	if ($table) {
		($tmp)=$table->getAttribs({'key'=>'ipmimaxp'},'value');
		if (defined($tmp)) { $ipmimaxp=$tmp->{value}; }
		($tmp)=$table->getAttribs({'key'=>'ipmitimeout'},'value');
		if (defined($tmp)) { $ipmitimeout=$tmp->{value}; }
		($tmp)=$table->getAttribs({'key'=>'ipmiretries'},'value');
		if (defined($tmp)) { $ipmitrys=$tmp->{value}; }
		($tmp)=$table->getAttribs({'key'=>'ipmisdrcache'},'value');
	}
	$table = xCAT::Table->new('passwd');
	if ($table) {
		($tmp)=$table->getAttribs({'key'=>'ipmi'},'username','password');
		if (defined($tmp)) {
			$ipmiuser = $tmp->{username};
			$ipmipass = $tmp->{password};
		}	
	}
	return($ipmiuser,$ipmipass,$ipmimaxp,$ipmitimeout,$ipmitrys);
}

sub ipmicmd {
	my $node = shift;
	$port = shift;
	$userid = shift;
	$passwd = shift;
	$timeout = shift;
	$localtrys = shift;
	$debug = shift;
	$localdebug = $debug;

	if($userid eq "(null)") {
		$userid = "";
	}
	if($passwd eq "(null)") {
		$passwd = "";
	}

	@user = dopad16($userid);
	@pass = dopad16($passwd);

	$seqlun = 0x00;
	@session_id = (0,0,0,0);
	@challenge = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
	@seqnum = (0,0,0,0);
	$authoffset=0;

	my $command = shift;
	my $subcommand = shift;
   my @leftovers = @_;

	my $rc=0;
	my $text="";
	my $error="";
	my @output;
	my $noclose=0;

	my $packed_ip = gethostbyname($node);
	if(!defined($packed_ip)) {
		$text = "failed to get IP for $node";
		return(2,$text);
	}
	my $nodeip = inet_ntoa($packed_ip);

	$sock = IO::Socket::INET->new(
		Proto => 'udp',
		PeerHost => $nodeip,
		PeerPort => $port,
	);
	if(!defined($sock)) {
		$text = "failed to get socket: $@\n";
		return(2,$text);
	}

	$error = getchanauthcap();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: gotchanauthcap\n";
	}

	if($command eq "ping") {
		return(0,"ping");
	}

	$error = getsessionchallenge();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: gotsessionchallenge\n";
	}

	$error = activatesession();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: active session\n";
	}

	$error = setprivlevel();
	if($error) {
		return(1,$error);
	}
	if($debug) {
		print "$node: priv level set\n";
	}

	if($command eq "rpower") {
		if($subcommand eq "stat" || $subcommand eq "state" || $subcommand eq "status") {
			($rc,$text) = power("stat");
		}
		elsif($subcommand eq "on") {
			($rc,$text) = power("on");
		}
		elsif($subcommand eq "nmi") {
			($rc,$text) = power("nmi");
		}
		elsif($subcommand eq "off") {
#
# e325 hack
#
#			my $mfg_id;
#			my $prod_id;
#			my $device_id;
#			my $text0;
#
#			($rc,$text,$mfg_id,$prod_id,$device_id) = getdevid();
#
#			if(0 && $mfg_id == 2 && ($prod_id == 0x8835 || $prod_id == 8835) && $device_id == 0) {
#				($rc,$text0) = power("reset");
#				sleep(5);
#			}
#
# e325 hack end
#
			($rc,$text) = power("off");
#
#			if($text0 ne "") {
#				$text = $text0 . " " . $text;
#			}
		}
		elsif($subcommand eq "reset") {
			($rc,$text) = power("reset");
			$noclose = 1;
		}
		elsif($subcommand eq "cycle") {
			my $text2;

			($rc,$text) = power("stat");

			if($rc == 0 && $text eq "on") {
				($rc,$text) = power("off");
				if($rc == 0) {
					sleep(5);
				}
			}

			if($rc == 0 && $text eq "off") {
				($rc,$text2) = power("on");
			}

			if($rc == 0) {	
				$text = $text . " " . $text2
			}
		}
		elsif($subcommand eq "boot") {
			my $text2;

			($rc,$text) = power("stat");

			if($rc == 0) {
				if($text eq "on") {
					($rc,$text2) = power("reset");
					$noclose = 1;
				}
				elsif($text eq "off") {
					($rc,$text2) = power("on");
				}
				else {
					$rc = 1;
				}
			
				$text = $text . " " . $text2
			}
		}
		else {
			$rc = 1;
			$text = "unsupported command $command $subcommand";
		}
	}
	elsif($command eq "rbeacon") {
		($rc,$text) = beacon($subcommand);
	}
#	elsif($command eq "info") {
#		if($subcommand eq "sensorname") {
#			($rc,$text) = initsdr();
#			if($rc == 0) {
#				my $key;
#				$text="";
#				foreach $key (keys %sdr_hash) {
#					my $sdr = $sdr_hash{$key};
#					if($sdr->sensor_number == @_) {
#						$text = $sdr_hash{$key}->id_string;
#						last;
#					}
#				}
##				if(defined $sdr_hash{@_}) {
##					$text = $sdr_hash{@_}->id_string;
##				}
#			}
#		}
#	}
	elsif($command eq "rvitals") {
		($rc,@output) = vitals($subcommand);
	}
	elsif($command eq "rspreset") {
		($rc,@output) = resetbmc();
		$noclose=1;
	}
	elsif($command eq "reventlog") {
		if($subcommand eq "decodealert") {
			($rc,$text) = decodealert(@_);
		}
		else {
			($rc,@output) = eventlog($subcommand);
		}
	}
	elsif($command eq "rinv") {
		($rc,@output) = inv($subcommand);
	}
	elsif($command eq "fru") {
		($rc,@output) = fru($subcommand);
	}
	elsif($command eq "sol.command") {
		my $dc=0;

		$@ = "";
		eval {
			my $cc=0;
			my $kid;
			my $pid=$$;

			$SIG{USR1} = sub {$cc=0;};
			$SIG{USR2} = sub {$dc++;};
			$SIG{CHLD} = sub {while(waitpid(-1,WNOHANG) > 0) { sleep(1); }};

			mkfifo("/tmp/.sol.$pid",0666);

			my $child = xCAT::Utils->xfork();
			if(!defined $child) {
				die;
			}

			if($child > 0) {
				$cc=1;
			}
			else {
				system("$subcommand /tmp/.sol.$pid");

				if($?/256 == 1) {
					kill(12,$pid);
				}
				if($?/256 == 2) {
					kill(12,$pid);
					sleep(1);
					kill(12,$pid);
				}

				kill(10,$pid);
				exit(0);
			}

			open(FH,"< /tmp/.sol.$pid");
			my $kpid = <FH>;
			close(FH);
			unlink("/tmp/.sol.$pid");

			while($cc == 1) {
				sleep(5);
				($rc,$text) = power("stat");
				$text="";
				if($rc != 0) {
					kill(15,$kpid);
					$cc=0;
				}
			}

			do {
				$kid = waitpid(-1,WNOHANG);
				sleep(1);
			} until($kid == -1);
		};
		if($@) {
			@output = $@;
		}

		$rc = $dc;
		if($rc == 1) {
			$noclose = 1;
		}
	}
	elsif($command eq "rgetnetinfo") {
      my @subcommands = ($subcommand);
		if($subcommand eq "all") {
			@subcommands = (
				"ip",
				"netmask",
				"gateway",
				"backupgateway",
				"snmpdest1",
				"snmpdest2",
				"snmpdest3",
				"snmpdest4",
				"community",
			);

			my @coutput;

			foreach(@subcommands) {
				$subcommand = $_;
				($rc,@output) = getnetinfo($subcommand);
				push(@coutput,@output);
			}

			@output = @coutput;
		}
		else {
			($rc,@output) = getnetinfo($subcommand);
		}
	}
	elsif($command eq "rspconfig") {
      foreach ($subcommand,@_) {
         my @coutput;
		   ($rc,@coutput) = setnetinfo($_);
		   if($rc == 0) {
			   ($rc,@coutput) = getnetinfo($_);
		   }
         push(@output,@coutput);
      }
	}
	elsif($command eq "sete325cli") {
		($rc,@output) = sete325cli($subcommand);
	}
	elsif($command eq "sete326cli") {
		($rc,@output) = sete325cli($subcommand);
	}
	elsif($command eq "generic") {
		($rc,@output) = generic($subcommand);
	}
	elsif($command eq "writefru") {
		($rc,@output) = writefru($subcommand,shift);
	}
	elsif($command eq "fru") {
		($rc,@output) = fru($subcommand);
	}
	elsif($command eq "rsetboot") {
        	($rc,@output) = setboot($subcommand);
	}

	else {
		$rc = 1;
		$text = "unsupported command $command $subcommand";
	}
	if($debug) {
		print "$node: command completed\n";
	}

	if($noclose == 0) {
		$error = closesession();
		if($error) {
			return(1,"$text, session close: $error");
		}
		if($debug) {
			print "$node: session closed.\n";
		}
	}

	if($text) {
		push(@output,$text);
	}

	$sock->close();
	return($rc,@output);
}

sub resetbmc {
	my $netfun = 0x18;
	my @cmd = (0x02);
	my @returnd = ();
	my $rc = 0;
	my $text;
	my $error;

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);
	if ($error) {
		$rc = 1;
		$text = $error;
	} else {
		if (0 == $returnd[36]) {
			$text = "BMC reset";
		} else {
			$text = sprintf("BMC Responded with code %d",$returnd[36]);
		}
	}
	return($rc,$text);
}

sub setnetinfo {
	my $subcommand = shift;
   my $argument;
   ($subcommand,$argument) = split(/=/,$subcommand);
	my @input = @_;

	my $netfun = 0x30;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;
	my $match;

	if($subcommand eq "snmpdest") {
		$subcommand = "snmpdest1";
	}

   unless(defined($argument)) { 
      return 0;
   }
   if ($subcommand eq "alert" and $argument eq "on" or $argument =~ /^en/ or $argument =~ /^enable/) {
      $netfun = 0x10;
      @cmd = (0x12,0x9,0x1,0x18,0x11,0x00);
   } elsif ($subcommand eq "alert" and $argument eq "off" or $argument =~ /^dis/ or $argument =~ /^disable/) {
      $netfun = 0x10;
      @cmd = (0x12,0x9,0x1,0x10,0x11,0x00);
   }
	elsif($subcommand eq "garp") {
		my $halfsec = $argument * 2; #pop(@input) * 2;

		if($halfsec > 255) {
			$halfsec = 255;
		}
		if($halfsec < 4) {
			$halfsec = 4;
		}

		@cmd = (0x01,$channel_number,0x0b,$halfsec);
	}
   elsif($subcommand =~ m/community/ ) {
      my $cindex = 0;
      my @clist;
      foreach (0..17) {
         push @clist,0;
      }
      foreach (split //,$argument)  {
         $clist[$cindex++]=ord($_);
      }
      @cmd = (1,$channel_number,0x10,@clist);
   }
	elsif($subcommand =~ m/snmpdest(\d+)/ ) {
		my $dstip = $argument; #pop(@input);
		my @dip = split /\./, $dstip;
		@cmd = (0x01,$channel_number,0x13,$1,0x00,0x00,$dip[0],$dip[1],$dip[2],$dip[3],0,0,0,0,0,0);
	}
	#elsif($subcommand eq "alert" ) {
	#    my $action=pop(@input);
            #print "action=$action\n";
        #    $netfun=0x28; #TODO: not right
 
            # mapping alert action to number
        #    my $act_number=8;   
        #    if ($action eq "on") {$act_number=8;}  
        #    elsif ($action eq "off") { $act_number=0;}  
        #    else { return(1,"unsupported alert action $action");}    
	#    @cmd = (0x12, $channel_number,0x09, 0x01, $act_number+16, 0x11,0x00);
	#}
	else {
		return(1,"configuration of $subcommand is not implemented currently");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "garp" or $subcommand =~ m/snmpdest\d+/ or $subcommand eq "alert" or $subcommand =~ /community/) {
			$code = $returnd[36];

			if($code == 0x00) {
				$text = "ok";
			}
		} 

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub getnetinfo {
	my $subcommand = shift;
   $subcommand =~ s/=.*//;

	my $netfun = 0x30;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;
	my $format = "%-25s";

	if ($subcommand eq "snmpdest") {
		$subcommand = "snmpdest1";
	}

   if ($subcommand eq "alert") {
      $netfun = 0x10;
      @cmd = (0x13,9,1,0);
   }
	elsif($subcommand eq "garp") {
		@cmd = (0x02,$channel_number,0x0b,0x00,0x00);
	}
	elsif ($subcommand =~ m/^snmpdest(\d+)/ ) {
		@cmd = (0x02,$channel_number,0x13,$1,0x00);
	}
	elsif ($subcommand eq "ip") {
		@cmd = (0x02,$channel_number,0x03,0x00,0x00);
	}
	elsif ($subcommand eq "netmask") {
		@cmd = (0x02,$channel_number,0x06,0x00,0x00);
	}
	elsif ($subcommand eq "gateway") {
		@cmd = (0x02,$channel_number,0x0C,0x00,0x00);
	}
	elsif ($subcommand eq "backupgateway") {
		@cmd = (0x02,$channel_number,0x0E,0x00,0x00);
	}
	elsif ($subcommand eq "community") {
		@cmd = (0x02,$channel_number,0x10,0x00,0x00);
	}
	else {
		return(1,"unsupported command getnetinfo $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "garp") {
			$code = $returnd[36];

			if($code == 0x00) {
				$code = $returnd[38] / 2;
				$text = sprintf("$format %d","Gratuitous ARP seconds:",$code);
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
      elsif($subcommand eq "alert") {
         if ($returnd[39] & 0x8) { 
            $text = "SP Alerting: enabled";
         } else {
            $text = "SP Alerting: disabled";
         }
      }
		elsif($subcommand =~ m/^snmpdest(\d+)/ ) {
			$text = sprintf("$format %d.%d.%d.%d",
				"SP SNMP Destination $1:",
				$returnd[41],
				$returnd[42],
				$returnd[43],
				$returnd[44]);
		}
		elsif($subcommand eq "ip") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC IP:",
				$returnd[38],
				$returnd[39],
				$returnd[40],
				$returnd[41]);
		}
		elsif($subcommand eq "netmask") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC Netmask:",
				$returnd[38],
				$returnd[39],
				$returnd[40],
				$returnd[41]);
		}
		elsif($subcommand eq "gateway") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC Gateway:",
				$returnd[38],
				$returnd[39],
				$returnd[40],
				$returnd[41]);
		}
		elsif($subcommand eq "backupgateway") {
			$text = sprintf("$format %d.%d.%d.%d",
				"BMC Backup Gateway:",
				$returnd[38],
				$returnd[39],
				$returnd[40],
				$returnd[41]);
		}
		elsif ($subcommand eq "community") {
			$text = sprintf("$format ","SP SNMP Community:");
			my $l = 38;
			while ($returnd[$l] ne 0) {
				$l = $l + 1;
			}
			my $i=38;
			while ($i<$l) {
				$text = $text . sprintf("%c",$returnd[$i]);
				$i = $i + 1;
			}
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub sete325cli {
	my $subcommand = shift;

	my $netfun = 0xc8;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	if($subcommand eq "disable") {
		@cmd = (0x00);
	}
	elsif($subcommand eq "cli") {
		@cmd = (0x02);
	}
	else {
		return(1,"unsupported command sete325cli $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($code == 0x00) {
			$rc = 0;
			$text = "$subcommand";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub setboot {
    my $subcommand=shift;
    my $netfun = 0x00;
    my @cmd = (0x08,0x3,0x8);
    my @returnd = ();
    my $error;
    my $rc = 0;
    my $text = "";
    my $code;
    my $skipset = 0;
    my %bootchoices = (
        0 => 'BIOS default',
        1 => 'Network',
        2 => 'Hard Drive',
        5 => 'CD/DVD',
        6 => 'BIOS Setup',
    );

    #This disables the 60 second timer
    $error = docmd(
        $netfun,
        \@cmd,
        \@returnd
    );
    if ($subcommand eq "net") {
        @cmd=(0x08,0x5,0x80,0x4,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "hd" ) {
        @cmd=(0x08,0x5,0x80,0x8,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "cd" ) {
        @cmd=(0x08,0x5,0x80,0x14,0x0,0x0,0x0);
    }
    elsif ($subcommand =~ m/^def/) {
        @cmd=(0x08,0x5,0x0,0x0,0x0,0x0,0x0);
    }
    elsif ($subcommand eq "setup" ) { #Not supported by BMCs I've checked so far..
        @cmd=(0x08,0x5,0x18,0x0,0x0,0x0,0x0);
    }
    elsif ($subcommand =~ m/^stat/) {
        $skipset=1;
    }
    else {
        return(1,"unsupported command setboot $subcommand");
    }


    unless ($skipset) {
        $error = docmd(
            $netfun,
            \@cmd,
            \@cmd,
            \@returnd
        );
        if($error) {
            return(1,$error);
        }
        $code = $returnd[36-$authoffset];
        unless ($code == 0x00) {
                    return(1,$codes{$code});
            }
    }
    @cmd=(0x09,0x5,0x0,0x0);
    $error = docmd(
                $netfun,
                \@cmd,
                \@returnd
        );
    if($error) {
                return(1,$error);
        }
    $code = $returnd[36-$authoffset];
    unless ($code == 0x00) {
                return(1,$codes{$code});
        }
    unless ($returnd[39-$authoffset] & 0x80) {
        $text = "boot override inactive";
        return($rc,$text);
    }
    my $boot=($returnd[40-$authoffset] & 0x3C) >> 2;
    $text = $bootchoices{$boot};
    return($rc,$text);
}

sub power {
	my $subcommand = shift;

	my $netfun = 0x00;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	if($subcommand eq "stat") {
		@cmd = (0x01);
	}
	elsif($subcommand eq "on") {
		@cmd = (0x02,0x01);
	}
	elsif($subcommand eq "off") {
		@cmd = (0x02,0x00);
	}
	elsif($subcommand eq "reset") {
		@cmd = (0x02,0x03);
	}
	elsif($subcommand eq "nmi") {
		@cmd = (0x02,0x04);
	}
	else {
		return(1,"unsupported command power $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "stat") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$code = $returnd[37-$authoffset];

				if($code & 0b00000001) {
					$text = "on";
				}
				else {
					$text = "off";
				}
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "nmi") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="nmi";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "on") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="on";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "off") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="off";
			}
			elsif($code == 0xd5) {
				$text="off";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "reset") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="reset";
			}
			elsif($code == 0xd5) {
				$text="off";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub generic {
	my $subcommand = shift;
	my $netfun;
	my @args;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	($netfun,@args) = split(/-/,$subcommand);

	$netfun=oct($netfun);
	printf("netfun:  0x%02x\n",$netfun);

	print "command: ";
	foreach(@args) {
		push(@cmd,oct($_));
		printf("0x%02x ",oct($_));
	}
	print "\n\n";

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	printf("return code: 0x%02x\n\n",$code);

	print "return data:\n";
	my @rdata = @returnd[37-$authoffset..@returnd-2]; 
	hexadump(\@rdata);
	print "\n";

	print "full output:\n";
	hexadump(\@returnd);
	print "\n";

#	if(!$text) {
#		$rc = 1;
#		$text = sprintf("unknown response %02x",$code);
#	}

	return($rc,$text);
}

sub beacon {
	my $subcommand = shift;

	my $netfun = 0x00;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	if($subcommand eq "on") {
        if ($ipmiv2) {
		    @cmd = (0x04,0x0,0x01);
        } else {
		    @cmd = (0x04,0xFF);
        }
	}
	elsif($subcommand eq "off") {
        if ($ipmiv2) {
            @cmd = (0x04,0x0,0x00);
        } else {
		    @cmd = (0x04,0x00);
        }
	}
	else {
		return(1,"unsupported command beacon $subcommand");
	}

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
	}
	else {
		if($subcommand eq "on") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="on";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}
		if($subcommand eq "off") {
			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
				$text="off";
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}
		}

		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
	}

	return($rc,$text);
}

sub inv {
	my $subcommand = shift;

	my $rc = 0;
	my $text;
	my @output;
	my @types;
	my $format = "%-20s %s";

	($rc,$text) = initfru();
	if($rc != 0) {
		return($rc,$text);
	}

	if($subcommand eq "all") {
		@types = qw(model serial deviceid mprom guid);
	}
	elsif($subcommand eq "model") {
		@types = qw(model);
	}
	elsif($subcommand eq "serial") {
		@types = qw(serial);
	}
	elsif($subcommand eq "vpd") {
		@types = qw(model serial deviceid mprom);
	}
	elsif($subcommand eq "mprom") {
		@types = qw(mprom);
	}
	elsif($subcommand eq "deviceid") {
		@types = qw(deviceid);
	}
	elsif($subcommand eq "guid") {
		@types = qw(guid);
	}
	elsif($subcommand eq "uuid") {
		@types = qw(guid);
	}
	else {
		return(1,"unsupported command inv $subcommand");
	}

	foreach(@types) {
		my $type = $_;
		my $otext;
		my $key;

		foreach $key (keys %fru_hash) {
			my $fru = $fru_hash{$key};
			#print($fru->rec_type."\n");
			if($fru->rec_type eq $type) {
				$otext = sprintf($format,$fru_hash{$key}->desc . ":",$fru_hash{$key}->value);
				#print $otext;
				push(@output,$otext);
			}
		}
	}

	return($rc,@output);
}

sub initoemfru {
	my $mfg_id = shift;
	my $prod_id = shift;
	my $device_id = shift;

	my $netfun;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;

	if($mfg_id == 2 && ($prod_id == 34869 or $prod_id == 31081 or $prod_id==34888)) {
		$netfun = 0xc8;
		
		@cmd=(0x05);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my @oem_fru_data = @returnd[37-$authoffset..@returnd-2];
		my $model_type = getascii(@oem_fru_data[0..3]);
		my $model_number = getascii(@oem_fru_data[4..6]);
		my $serial = getascii(@oem_fru_data[7..13]);
		my $model = "$model_type-$model_number";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 4 && 0) {
		$netfun = 0x3a;
		
		@cmd=(0x0b,0x0,0x0,0x0,0x1,0x8);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

hexadump(\@returnd);
return(2,"");

		my @oem_fru_data = @returnd[37-$authoffset..@returnd-2];
		my $model_type = getascii(@oem_fru_data[0..3]);
		my $model_number = getascii(@oem_fru_data[4..6]);
		my $serial = getascii(@oem_fru_data[7..13]);
		my $model = "$model_type-$model_number";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 20) {
		my $serial = "unknown";
		my $model = "x3655";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 3) {
		my $serial = "unknown";
		my $model = "x346";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
	if($mfg_id == 2 && $prod_id == 4) {
		my $serial = "unknown";
		my $model = "x336";

		my $fru = FRU->new();
		$fru->rec_type("serial");
		$fru->desc("Serial Number");
		$fru->value($serial);
		$fru_hash{1} = $fru;

		$fru = FRU->new();
		$fru->rec_type("model");
		$fru->desc("Model Number");
		$fru->value($model);
		$fru_hash{2} = $fru;

		return(2,"");
	}
   my $serial = "unkown";
   my $model = "unkown";

   my $fru = FRU->new();
	$fru->rec_type("serial");
	$fru->desc("Serial Number");
	$fru->value($serial);
	$fru_hash{1} = $fru;

	$fru = FRU->new();
	$fru->rec_type("model");
	$fru->desc("Model Number");
	$fru->value($model);
	$fru_hash{2} = $fru;

	return(2,"");


	return(1,"No OEM FRU Support");
}

sub initfru {
	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;

	my $mfg_id;
	my $prod_id;
	my $device_id;
	my $dev_rev;
	my $fw_rev1;
	my $fw_rev2;
	my $mprom;
	my $fru;
	my $guid;
	my @guidcmd;

	($rc,$text,$mfg_id,$prod_id,$device_id,$dev_rev,$fw_rev1,$fw_rev2) = getdevid();
	if($rc != 0) {
		return($rc,$text);
	}

	@guidcmd = (0x18,0x37);
	if($mfg_id == 2 && $prod_id == 34869) {
		@guidcmd = (0x18,0x08);
	}
	if($mfg_id == 2 && $prod_id == 4) {
		@guidcmd = (0x18,0x08);
	}
	if($mfg_id == 2 && $prod_id == 3) {
		@guidcmd = (0x18,0x08);
	}

	($rc,$text,$guid) = getguid(\@guidcmd);
	if($rc != 0) {
		return($rc,$text);
	}

	if($mfg_id == 2 && $prod_id == 34869) {
		$mprom = sprintf("%x.%x",$fw_rev1,$fw_rev2);
	}
	else {
		my @lcmd = (0x50);
		my @lreturnd = ();
		my $lerror = docmd(
			0xe8,
			\@lcmd,
			\@lreturnd
		);
		if ($lerror == 0 && $lreturnd[36-$authoffset] == 0) {
			my @a = ($fw_rev2);
			my @b= @lreturnd[37-$authoffset .. $#lreturnd-1];
			$mprom = sprintf("%d.%s (%s)",$fw_rev1,decodebcd(\@a),getascii(@b));
		} else {
			my @a = ($fw_rev2);
			$mprom = sprintf("%d.%s",$fw_rev1,decodebcd(\@a));
		}
	}

	$fru = FRU->new();
	$fru->rec_type("mprom");
	$fru->desc("BMC Firmware");
	$fru->value($mprom);
	$fru_hash{mprom} = $fru;

	$fru = FRU->new();
	$fru->rec_type("guid");
	$fru->desc("GUID");
	$fru->value($guid);
	$fru_hash{guid} = $fru;

	$fru = FRU->new();
	$fru->rec_type("deviceid");
	$fru->desc("Manufacturer ID");
	my $value = $mfg_id;
	if($MFG_ID{$mfg_id}) {
		$value = "$MFG_ID{$mfg_id} ($mfg_id)";
	}
	$fru->value($value);
	$fru_hash{mfg_id} = $fru;

	$fru = FRU->new();
	$fru->rec_type("deviceid");
	$fru->desc("Product ID");
	$value = $prod_id;
	my $tmp = "$mfg_id:$prod_id";
	if($PROD_ID{$tmp}) {
		$value = "$PROD_ID{$tmp} ($prod_id)";
	}
	$fru->value($value);
	$fru_hash{prod_id} = $fru;

	$fru = FRU->new();
	$fru->rec_type("deviceid");
	$fru->desc("Device ID");
	$fru->value($device_id);
	$fru_hash{device_id} = $fru;

#	($rc,$text)=initoemfru($mfg_id,$prod_id,$device_id);
#	if($rc == 1) {
#		return($rc,$text);
#	}
#	if($rc == 2) {
#		return(0,"");
#	}

	@cmd=(0x10,0x00);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	if($rc != 0) {
		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	my $fru_size_ls = $returnd[37-$authoffset];
	my $fru_size_ms = $returnd[38-$authoffset];
	my $fru_size = $fru_size_ms*256 + $fru_size_ls;
	my $fru_bytes_words = $returnd[39-$authoffset] & 1;

	($rc,@output) = frudump(0,8,8);
	if($rc != 0) {
		return($rc,@output);
	}

	my $fru_header_ver = $output[0];
	my $fru_header_offset_internal = $output[1];
	my $fru_header_offset_chassis = $output[2] * 8;
	my $fru_header_offset_board = $output[3];
	my $fru_header_offset_product = $output[4];
	my $fru_header_offset_mult = $output[5];

	if($fru_header_ver != 1) {
		($rc,$text)=initoemfru($mfg_id,$prod_id,$device_id);
		if($rc == 1) {
			$text = "FRU format unknown";
			return($rc,$text);
		}
		if($rc == 2) {
			return(0,"");
		}
	}

	($rc,@output) = frudump($fru_header_offset_chassis,2,8);
	if($rc != 0) {
		return($rc,@output);
	}

	my $chassis_info_area_format_version = $output[0];
	my $chassis_info_area_length = $output[1] * 8;

	if($chassis_info_area_format_version != 1) {
		($rc,$text)=initoemfru($mfg_id,$prod_id,$device_id);
		if($rc == 1) {
			$text = "FRU format unknown";
			return($rc,$text);
		}
		if($rc == 2) {
			return(0,"");
		}
	}

	($rc,@output) = frudump($fru_header_offset_chassis,$chassis_info_area_length,8);
	if($rc != 0) {
		return($rc,@output);
	}

	my $c=2;
	my $chassis_type = $output[$c++];
	my $chassis_part_num_type = ($output[$c] & 0b11000000) >> 6;
	my $chassis_part_num_len = $output[$c] & 0b00111111;
	my $chassis_part_num;
	$c++;
	if($chassis_part_num_type == 3) {
		$chassis_part_num = getascii(@output[$c..$c+$chassis_part_num_len-1]);
	}
	else {
		$chassis_part_num = "unsupported type $chassis_part_num_type";
	}
	$c=$c+$chassis_part_num_len;
	my $chassis_serial_num_type = ($output[$c] & 0b11000000) >> 6;
	my $chassis_serial_num_len = $output[$c] & 0b00111111;
	my $chassis_serial_num;
	$c++;
	if($chassis_serial_num_type == 3) {
		$chassis_serial_num = getascii(@output[$c..$c+$chassis_serial_num_len-1]);
	}
	else {
		$chassis_serial_num = "unsupported type $chassis_serial_num_type";
	}
	if(!$chassis_part_num) {
		$chassis_part_num = "undefined";
	}
	if(!$chassis_serial_num) {
		$chassis_serial_num = "undefined";
	}

	$fru = FRU->new();
	$fru->rec_type("serial");
	$fru->desc("Serial Number");
	$fru->value($chassis_serial_num);
	$fru_hash{1} = $fru;

	if($chassis_types{$chassis_type}) {
		$chassis_part_num .= " ";
		$chassis_part_num .= $chassis_types{$chassis_type};
	}

	$fru = FRU->new();
	$fru->rec_type("model");
	$fru->desc("Model Number");
	$fru->value($chassis_part_num);
	$fru_hash{2} = $fru;

	return($rc,$text);
}

sub fru {
	my $subcommand = shift;
	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;

	@cmd=(0x10,0x00);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	if($rc != 0) {
		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	my $fru_size_ls = $returnd[37-$authoffset];
	my $fru_size_ms = $returnd[38-$authoffset];
	my $fru_size = $fru_size_ms*256 + $fru_size_ls;
	my $fru_bytes_words = $returnd[39-$authoffset] & 1;

	if($subcommand eq "dump") {
		print "FRU Size: $fru_size\n";
		my ($rc,@output) = frudump(0,$fru_size,8);
		if($rc) {
			return($rc,@output);
		}
		hexadump(\@output);
		return(0,"");
	}
	if($subcommand eq "wipe") {
		my @bytes = ();

		for(my $i = 0;$i < $fru_size;$i++) {
			push(@bytes,0xff);
		}
		my ($rc,$text) = fruwrite(0,\@bytes,8);
		if($rc) {
			return($rc,$text);
		}
		return(0,"FRU $fru_size bytes wiped");
	}

	return(0,"");
}

sub frudump {
	my $offset = shift;
	my $length = shift;
	my $chunk = shift;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;
	my @fru_data=();

	for(my $c=$offset;$c < $length+$offset;$c += $chunk) {
		my $ms = int($c / 0x100);
		my $ls = $c - $ms * 0x100;

		@cmd=(0x11,0x00,$ls,$ms,$chunk);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my $count = $returnd[37-$authoffset];
		if($count != $chunk) {
			$rc = 1;
			$text = "FRU read error (bytes requested: $chunk, got: $count)";
			return($rc,$text);
		}

		my @data = @returnd[38-$authoffset..@returnd-2];
		@fru_data = (@fru_data,@data);
	}

	return(0,@fru_data);
}

sub writefru {
	my $serial = shift;
	my $model = shift;
	my @bytes;
	my $rc;
	my $text;

	#header
	@bytes = (0x01,0x01,0x02,0x00,0x00,0x00,0x00);
	@bytes = (@bytes,dochksum(\@bytes));

	($rc,$text) = fruwrite(0,\@bytes,8);
	if($rc) {
		return($rc,$text);
	}

	#internal use area
	@bytes = (0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00);

	($rc,$text) = fruwrite(8,\@bytes,8);
	if($rc) {
		return($rc,$text);
	}

	#chassis info area
	@bytes = (0x01,0x04,0x17);
	push(@bytes,0b11000000 + length($model));
	@bytes = (@bytes,unpack("C*",$model));
	push(@bytes,0b11000000 + length($serial));
	@bytes = (@bytes,unpack("C*",$serial));
	push(@bytes,0xc1);

	foreach(@bytes..30) {
		push(@bytes,0x00);
	}
	@bytes = (@bytes,dochksum(\@bytes));

	if(@bytes > 32) {
		return(1,"Serial + Model too long");
	}

	($rc,$text) = fruwrite(16,\@bytes,8);
	if($rc) {
		return($rc,$text);
	}

	return(0,"FRU Updated");
}

sub fruwrite {
	my $offset = shift;
	my $bytes = shift;
	my $chunk = shift;
	my $length = @$bytes;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my @output;
	my $code;
	my @fru_data=();

	for(my $c=$offset;$c < $length+$offset;$c += $chunk) {
		my $ms = int($c / 0x100);
		my $ls = $c - $ms * 0x100;

		@cmd=(0x12,0x00,$ls,$ms,@$bytes[$c-$offset..$c-$offset+$chunk-1]);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my $count = $returnd[37-$authoffset];
		if($count != $chunk) {
			$rc = 1;
			$text = "FRU write error (bytes requested: $chunk, wrote: $count)";
			return($rc,$text);
		}
	}

	return(0);
}

sub decodealert {
  my $trap = shift;
  my $skip_sdrinit=0;
  if ($trap =~ /xCAT_plugin::ipmi/) {
    $trap=shift;
    $skip_sdrinit=1;
  }
	my $node = shift;
	my @pet = @_;
	my $rc;
	my $text;
    
    if (!$skip_sdrinit) { 
	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}
    }

	my $type;
	my $desc;
	#my $ipmisensoreventtab = "$ENV{XCATROOT}/lib/GUMI/ipmisensorevent.tab";
	#my $ipmigenericeventtab = "$ENV{XCATROOT}/lib/GUMI/ipmigenericevent.tab";

	my $offsetmask     = 0b00000000000000000000000000001111;
	my $offsetrmask    = 0b00000000000000000000000001110000;
	my $assertionmask  = 0b00000000000000000000000010000000;
	my $eventtypemask  = 0b00000000000000001111111100000000;
	my $sensortypemask = 0b00000000111111110000000000000000;
	my $reservedmask   = 0b11111111000000000000000000000000;

	my $offset      = $trap & $offsetmask;
	my $offsetr     = $trap & $offsetrmask;
	my $event_dir   = $trap & $assertionmask;
	my $event_type  = ($trap & $eventtypemask) >> 8;
	my $sensor_type = ($trap & $sensortypemask) >> 16;
	my $reserved    = ($trap & $reservedmask) >> 24;

	if($debug >= 2) {
		printf("offset:     %02xh\n",$offset);
		printf("offsetr:    %02xh\n",$offsetr);
		printf("assertion:  %02xh\n",$event_dir);
		printf("eventtype:  %02xh\n",$event_type);
		printf("sensortype: %02xh\n",$sensor_type);
		printf("reserved:   %02xh\n",$reserved);
	}

	my @hex = (0,@pet);
	my $pad = $hex[0];
	my @uuid = @hex[1..16];
	my @seqnum = @hex[17,18];
	my @timestamp = @hex[19,20,21,22];
	my @utcoffset = @hex[23,24];
	my $trap_source_type = $hex[25];
	my $event_source_type = $hex[26];
	my $sev = $hex[27];
	my $sensor_device = $hex[28];
	my $sensor_num = $hex[29];
	my $entity_id = $hex[30];
	my $entity_instance = $hex[31];
	my $event_data_1 = $hex[32];
	my $event_data_2 = $hex[33];
	my $event_data_3 = $hex[34];
	my @event_data = @hex[35..39];
	my $langcode = $hex[40];
	my $mfg_id = $hex[41] + $hex[42] * 0x100 + $hex[43] * 0x10000 + $hex[44] * 0x1000000;
	my $prod_id = $hex[45] + $hex[46] * 0x100;
	my @oem = $hex[47..@hex-1];

	if($sev == 0x00) {
		$sev = "LOG";
	}
	elsif($sev == 0x01) {
		$sev = "MONITOR";
	}
	elsif($sev == 0x02) {
		$sev = "INFORMATION";
	}
	elsif($sev == 0x04) {
		$sev = "OK";
	}
	elsif($sev == 0x08) {
		$sev = "WARNING";
	}
	elsif($sev == 0x10) {
		$sev = "CRITICAL";
	}
	elsif($sev == 0x20) {
		$sev = "NON-RECOVERABLE";
	}
	else {
		$sev = "UNKNOWN-SEVERITY:$sev";
	}
	$text = "$sev:";

	($rc,$type,$desc) = getsensorevent($sensor_type,$offset,"ipmisensorevents");
	if($rc == 1) {
		$type = "Unknown Type $sensor_type";
		$desc = "Unknown Event $offset";
		$rc = 0;
	}

	if($event_type <= 0x0c) {
		my $gtype;
		my $gdesc;
		($rc,$gtype,$gdesc) = getsensorevent($event_type,$offset,"ipmigenericevents");
		if($rc == 1) {
			$gtype = "Unknown Type $gtype";
			$gdesc = "Unknown Event $offset";
			$rc = 0;
		}

		$desc = $gdesc;
	}

	if($type eq "" || $type eq "-") {
		$type = "OEM Sensor Type $sensor_type"
	}
	if($desc eq "" || $desc eq "-") {
		$desc = "OEM Sensor Event $offset"
	}

	if($type eq $desc) {
		$desc = "";
	}

	my $extra_info = getaddsensorevent($sensor_type,$offset,$event_data_1,$event_data_2,$event_data_3);
	if($extra_info) {
		if($desc) {
			$desc = "$desc $extra_info";
		}
		else {
			$desc = "$extra_info";
		}
	}

	$text = "$text $type,";
	$text = "$text $desc";

	my $key;
	my $sensor_desc = sprintf("Sensor 0x%02x",$sensor_num);
	foreach $key (keys %sdr_hash) {
		my $sdr = $sdr_hash{$key};
		if($sdr->sensor_number == $sensor_num) {
			$sensor_desc = $sdr_hash{$key}->id_string;
			if($sdr->rec_type == 0x01) {
				last;
			}
		}
	}

	$text = "$text ($sensor_desc)";

	if($event_dir) {
		$text = "$text - Recovered";
	}

	return(0,$text);
}

sub eventlog {
	my $subcommand = shift;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;
	my @output;
	my $num;
	my $entry;
	my @sel;
	#my $ipmisensoreventtab = "$ENV{XCATROOT}/lib/GUMI/ipmisensorevent.tab";
	#my $ipmigenericeventtab = "$ENV{XCATROOT}/lib/GUMI/ipmigenericevent.tab";
	my $mfg_id;
	my $prod_id;
	my $device_id;

	($rc,$text,$mfg_id,$prod_id,$device_id) = getdevid();
	$rc=0;
	if($subcommand eq "all") {
		$num = 0x100 * 0x100;
	}
	elsif($subcommand eq "clear") {
	}
	elsif($subcommand =~ /^\d+$/) {
		$num = $subcommand;
	}
	else {
		return(1,"unsupported command eventlog $subcommand");
	}

	@cmd=(0x40);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	elsif($code == 0x81) {
		$rc = 1;
		$text = "cannot execute command, SEL erase in progress";
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	if($rc != 0) {
		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	my $sel_version = $returnd[37-$authoffset];
	if($sel_version != 0x51) {
		$rc = 1;
		$text = sprintf("SEL version 51h support only, version reported: %x",$sel_version);
		return($rc,$text);
	}

	my $num_entries = $returnd[39-$authoffset]*256 + $returnd[38-$authoffset];
	if($num_entries <= 0) {
		$rc = 1;
		$text = "no SEL entries";
		return($rc,$text);
	}

	my $canres = $returnd[50-$authoffset] & 0b00000010;
	if(!$canres) {
		$rc = 1;
		$text = "SEL reservation not supported";
		return($rc,$text);
	}

	@cmd=(0x42);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];

	if($code == 0x00) {
	}
	elsif($code == 0x81) {
		$rc = 1;
		$text = "cannot execute command, SEL erase in progress";
	}
	else {
		$rc = 1;
		$text = $codes{$code};
	}

	if($rc != 0) {
		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	my $res_id_ls = $returnd[37-$authoffset];
	my $res_id_ms = $returnd[38-$authoffset];

	if($subcommand eq "clear") {
		@cmd=(0x47,$res_id_ls,$res_id_ms,0x43,0x4c,0x52,0xaa);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}

		my $erase_status = $returnd[37-$authoffset] & 0b00000001;

#skip test for now, need to get new res id for some machines
		while($erase_status == 0 && 0) {
			sleep(1);
			@cmd=(0x47,$res_id_ls,$res_id_ms,0x43,0x4c,0x52,0x00);
			$error = docmd(
				$netfun,
				\@cmd,
				\@returnd
			);

			if($error) {
				$rc = 1;
				$text = $error;
				return($rc,$text);
			}

			$code = $returnd[36-$authoffset];

			if($code == 0x00) {
			}
			else {
				$rc = 1;
				$text = $codes{$code};
			}

			if($rc != 0) {
				if(!$text) {
					$text = sprintf("unknown response %02x",$code);
				}
				return($rc,$text);
			}

			$erase_status = $returnd[37-$authoffset] & 0b00000001;
		}

		$text = "SEL cleared";
		return($rc,$text);
	}

	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}

	@cmd=(0x43,$res_id_ls,$res_id_ms,0x00,0x00,0x00,0xFF);
	while(1) {
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
         push(@output,$text);
			return($rc,@output);
		}

		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
		}
		elsif($code == 0x81) {
			$rc = 1;
			$text = "cannot execute command, SEL erase in progress";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
		}

		if($rc != 0) {
			if(!$text) {
				$text = sprintf("unknown response %02x",$code);
			}
         push(@output,$text);
			return($rc,@output);
		}

		my $next_rec_ls = $returnd[37-$authoffset];
		my $next_rec_ms = $returnd[38-$authoffset];
		my @sel_data = @returnd[39-$authoffset..39-$authoffset+16];
		@cmd=(0x43,$res_id_ls,$res_id_ms,$next_rec_ls,$next_rec_ms,0x00,0xFF);

		$entry++;
		if($debug) {
			print "$entry: ";
			hexdump(\@sel_data);
		}

		my $record_id = $sel_data[0] + $sel_data[1]*256;
		my $record_type = $sel_data[2];

		if($record_type == 0x02) {
		}
		else {
			$text=getoemevent($record_type,$mfg_id,\@sel_data);
			push(@output,$text);
			if($next_rec_ms == 0xFF && $next_rec_ls == 0xFF) {
				last;
			}
			next;
		}

		my $timestamp = $sel_data[3] + $sel_data[4]*0x100 + $sel_data[5]*0x10000 + $sel_data[6]*0x1000000;
		my ($seldate,$seltime) = timestamp2datetime($timestamp);
#		$text = "$entry: $seldate $seltime";
		$text = ":$seldate $seltime";

#		my $gen_id_slave_addr = ($sel_data[7] & 0b11111110) >> 1;
#		my $gen_id_slave_addr_hs = ($sel_data[7] & 0b00000001);
#		my $gen_id_ch_num = ($sel_data[8] & 0b11110000) >> 4;
#		my $gen_id_ipmb = ($sel_data[8] & 0b00000011);

		my $sensor_owner_id = $sel_data[7];
		my $sensor_owner_lun = $sel_data[8];

		my $sensor_type = $sel_data[10];
		my $sensor_num = $sel_data[11];
		my $event_dir = $sel_data[12] & 0b10000000;
		my $event_type = $sel_data[12] & 0b01111111;
		my $offset = $sel_data[13] & 0b00001111;
		my $event_data_1 = $sel_data[13];
		my $event_data_2 = $sel_data[14];
		my $event_data_3 = $sel_data[15];
		my $sev = 0;
		$sev = ($sel_data[14] & 0b11110000) >> 4;
#		if($event_type != 1) {
#			$sev = ($sel_data[14] & 0b11110000) >> 4;
#		}
#		$text = "$text $sev:";

		my $type;
		my $desc;
		($rc,$type,$desc) = getsensorevent($sensor_type,$offset,"ipmisensorevents");
		if($rc == 1) {
			$type = "Unknown Type $sensor_type";
			$desc = "Unknown Event $offset";
			$rc = 0;
		}

		if($event_type <= 0x0c) {
			my $gtype;
			my $gdesc;
			($rc,$gtype,$gdesc) = getsensorevent($event_type,$offset,"ipmigenericevents");
			if($rc == 1) {
				$gtype = "Unknown Type $gtype";
				$gdesc = "Unknown Event $offset";
				$rc = 0;
			}

			$desc = $gdesc;
		}

		if($type eq "" || $type eq "-") {
			$type = "OEM Sensor Type $sensor_type"
		}
		if($desc eq "" || $desc eq "-") {
			$desc = "OEM Sensor Event $offset"
		}

		if($type eq $desc) {
			$desc = "";
		}

		my $extra_info = getaddsensorevent($sensor_type,$offset,$event_data_1,$event_data_2,$event_data_3);
		if($extra_info) {
			if($desc) {
				$desc = "$desc $extra_info";
			}
			else {
				$desc = "$extra_info";
			}
		}

		$text = "$text $type,";
		$text = "$text $desc";

#		my $key;
		my $key = $sensor_owner_id . "." . $sensor_owner_lun . "." . $sensor_num;
		my $sensor_desc = sprintf("Sensor 0x%02x",$sensor_num);
#		foreach $key (keys %sdr_hash) {
#			my $sdr = $sdr_hash{$key};
#			if($sdr->sensor_number == $sensor_num) {
#				$sensor_desc = $sdr_hash{$key}->id_string;
#				last;
#			}
#		}
		if(defined $sdr_hash{$key}) {
			$sensor_desc = $sdr_hash{$key}->id_string;
         if ($sdr_hash{$key}->event_type_code == 1) {
            if (($event_data_1 & 0b11000000) == 0b01000000) {
               $sensor_desc .= " reading ".translate_sensor($event_data_2,$sdr_hash{$key});
               if (($event_data_1 & 0b00110000) == 0b00010000) {
                  $sensor_desc .= " with threshold " . translate_sensor($event_data_3,$sdr_hash{$key});
               }
            }
         }
		}

		$text = "$text ($sensor_desc)";

		if($event_dir) {
			$text = "$text - Recovered";
		}

		push(@output,$text);

		if($next_rec_ms == 0xFF && $next_rec_ls == 0xFF) {
			last;
		}
	}

	my @routput = reverse(@output);
	my @noutput;
	my $c;
	foreach(@routput) {
		$c++;
		if($c > $num) {
			last;
		}
		push(@noutput,$_);
	}
	@output = reverse(@noutput);

	return($rc,@output);
}
sub getoemevent {
	my $record_type = shift;
	my $mfg_id = shift;
	my $sel_data = shift;
	my $text="";
	if ($record_type < 0xE0 && $record_type > 0x2F) { #Should be timestampped, whatever it is
		my $timestamp =  @$sel_data[3] + @$sel_data[4]*0x100 + @$sel_data[5]*0x10000 + @$sel_data[6]*0x1000000;
		my ($seldate,$seltime) = timestamp2datetime($timestamp);
		my @rest = @$sel_data[7..15];
		if ($mfg_id==2) {
			$text="$seldate $seltime IBM OEM Event-";
			if ($rest[3]==0 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."PCI Event/Error, details in next event"
			} elsif ($rest[3]==1 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Processor Event/Error occurred, details in next event"
			} elsif ($rest[3]==2 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Memory Event/Error occurred, details in next event"
			} elsif ($rest[3]==3 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Scalability Event/Error occurred, details in next event"
			} elsif ($rest[3]==4 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."PCI bus Event/Error occurred, details in next event"
			} elsif ($rest[3]==5 && $rest[4]==0 && $rest[7]==0) {
				$text=$text."Chipset Event/Error occurred, details in next event"
			} elsif ($rest[3]==6 && $rest[4]==1 && $rest[7]==0) {
				$text=$text."BIOS/BMC Power Executive mismatch (BIOS $rest[5], BMC $rest[6])"
			} elsif ($rest[3]==6 && $rest[4]==2 && $rest[7]==0) {
				$text=$text."Boot denied due to power limitations"
			} else {
				$text=$text."Unknown event ". phex(\@rest);
			}
		} else {
		     $text = "$seldate $seltime " . sprintf("Unknown OEM SEL Type %02x:",$record_type) . phex(\@rest);
		}
	} else { #Non-timestamped
		my %memerrors = (
			0x00 => "DIMM enabled",
			0x01 => "DIMM disabled, failed ECC test",
			0x02 => "POST/BIOS memory test failed, DIMM disabled",
			0x03 => "DIMM disabled, non-supported memory device",
			0x04 => "DIMM disabled, non-matching or missing DIMM(s)",
		);
		my %pcierrors = (
			0x00 => "Device OK",
			0x01 => "Required ROM space not available",
			0x02 => "Required I/O Space not available",
			0x03 => "Required memory not available",
			0x04 => "Required memory below 1MB not available",
			0x05 => "ROM checksum failed",
			0x06 => "BIST failed",
			0x07 => "Planar device missing or disabled by user",
			0x08 => "PCI device has an invalid PCI configuration space header",
			0x09 => "FRU information for added PCI device",
			0x0a => "FRU information for removed PCI device",
			0x0b => "A PCI device was added, PCI FRU information is stored in next log entry",
			0x0c => "A PCI device was removed, PCI FRU information is stored in next log entry",
			0x0d => "Requested resources not available",
			0x0e => "Required I/O Space Not Available",
			0x0f => "Required I/O Space Not Available",
			0x10 => "Required I/O Space Not Available",
			0x11 => "Required I/O Space Not Available",
			0x12 => "Required I/O Space Not Available",
			0x13 => "Planar video disabled due to add in video card",
			0x14 => "FRU information for PCI device partially disabled ",
			0x15 => "A PCI device was partially disabled, PCI FRU information is stored in next log entry",
			0x16 => "A 33Mhz device is installed on a 66Mhz bus, PCI device information is stored in next log entry",
			0x17 => "FRU information, 33Mhz device installed on 66Mhz bus",
			0x18 => "Merge cable missing",
			0x19 => "Node 1 to Node 2 cable missing",
			0x1a => "Node 1 to Node 3 cable missing",
			0x1b => "Node 2 to Node 3 cable missing",
			0x1c => "Nodes could not merge",
			0x1d => "No 8 way SMP cable",
			0x1e => "Primary North Bridge to PCI Host Bridge IB Link has failed",
			0x1f => "Redundant PCI Host Bridge IB Link has failed",
		);
		my %procerrors = (
			0x00 => "Processor has failed BIST",
			0x01 => "Unable to apply processor microcode update",
			0x02 => "POST does not support current stepping level of processor",
			0x03 => "CPU mismatch detected",
		);
		my @rest = @$sel_data[3..15];
		if ($record_type == 0xE0 && $rest[0]==2 && $mfg_id==2 && $rest[1]==0 && $rest[12]==1) { #Rev 1 POST memory event
			$text="IBM Memory POST Event-";
			my $msuffix=sprintf(", chassis %d, card %d, dimm %d",$rest[3],$rest[4],$rest[5]);
			#the next bit is a basic lookup table, should implement as a table ala ibmleds.tab, or a hash... yeah, a hash...
			$text=$text.$memerrors{$rest[2]}.$msuffix;
		} elsif ($record_type == 0xE0 && $rest[0]==1 && $mfg_id==2 && $rest[12]==0) { #A processor error or event, rev 0 only known in the spec I looked at
			$text=$text.$procerrors{$rest[1]};
		} elsif ($record_type == 0xE0 && $rest[0]==0 && $mfg_id==2) { #A PCI error or event, rev 1 or 2, the revs differe in endianness
			my $msuffix;
			if ($rest[12]==0) {
				$msuffix=sprintf("chassis %d, slot %d, bus %s, device %02x%02x:%02x%02x",$rest[2],$rest[3],$rest[4],$rest[5],$rest[6],$rest[7],$rest[8]);
			} elsif ($rest[12]==1) {
				$msuffix=sprintf("chassis %d, slot %d, bus %s, device %02x%02x:%02x%02x",$rest[2],$rest[3],$rest[4],$rest[5],$rest[6],$rest[7],$rest[8]);
			} else {
				return ("Unknown IBM PCI event/error format");
			}
			$text=$text.$pcierrors{$rest[1]}.$msuffix;
		} else {
			#Some event we can't define that is OEM or some otherwise unknown event
			$text = sprintf("SEL Type %02x:",$record_type) . phex(\@rest);
		}
	} #End timestampped intepretation
	return ($text);
}

sub getsensorevent
{
	my $sensortype = sprintf("%02Xh",shift);
	my $sensoroffset = sprintf("%02Xh",shift);
	my $file = shift;

	my @line;
	my $type;
	my $code;
	my $desc;
	my $offset;
	my $rc = 1;

    if ($file eq "ipmigenericevents") {
      if ($xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,$sensoroffset"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,$sensoroffset"},2);
	    return(0,$type,$desc);
      }
      if ($xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,-"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmigenericevents::ipmigenericevents{"$sensortype,-"},2);
	    return(0,$type,$desc);
       }
    }
    if ($file eq "ipmisensorevents") {
      if ($xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,$sensoroffset"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,$sensoroffset"},2);
	    return(0,$type,$desc);
      }
      if ($xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,-"}) {
        ($type,$desc) = split (/,/,$xCAT::data::ipmisensorevents::ipmisensorevents{"$sensortype,-"},2);
	    return(0,$type,$desc);
       }
    }
    return (0,"No Mappings found","No Mappings found");
}

sub getaddsensorevent {
	my $sensor_type = shift;
	my $offset = shift;
	my $event_data_1 = shift;
	my $event_data_2 = shift;
	my $event_data_3 = shift;
	my $text = "";

	if($sensor_type == 0x0f) {
		if($offset == 0x00) {
			my %extra = (
				0x00 => "Unspecified",
				0x01 => "No system memory installed",
				0x02 => "No usable system memory",
				0x03 => "Unrecoverable hard disk failure",
				0x04 => "Unrecoverable system board failure",
				0x05 => "Unrecoverable diskette failure",
				0x06 => "Unrecoverable hard disk controller failure",
				0x07 => "Unrecoverable keyboard failure",
				0x08 => "Removable boot media not found",
				0x09 => "Unrecoverable video controller failure",
				0x0a => "No video device detected",
				0x0b => "Firmware (BIOS) ROM corruption detected",
				0x0c => "CPU voltage mismatch",
				0x0d => "CPU speed matching failure",
			);
			$text = $extra{$event_data_2};
		}
		if($offset == 0x02) {
			my %extra = (
				0x00 => "Unspecified",
				0x01 => "Memory initialization",
				0x02 => "Hard-disk initialization",
				0x03 => "Secondary processor(s) initialization",
				0x04 => "User authentication",
				0x05 => "User-initiated system setup",
				0x06 => "USB resource configuration",
				0x07 => "PCI resource configuration",
				0x08 => "Option ROM initialization",
				0x09 => "Video initialization",
				0x0a => "Cache initialization",
				0x0b => "SM Bus initialization",
				0x0c => "Keyboard controller initialization",
				0x0d => "Embedded controller/management controller initialization",
				0x0e => "Docking station attachement",
				0x0f => "Enabling docking station",
				0x10 => "Docking staion ejection",
				0x11 => "Disable docking station",
				0x12 => "Calling operation system wake-up vector",
				0x13 => "Starting operation system boot process, call init 19h",
				0x14 => "Baseboard or motherboard initialization",
				0x16 => "Floppy initialization",
				0x17 => "Keyboard test",
				0x18 => "Pointing device test",
				0x19 => "Primary processor initialization",
			);
			$text = $extra{$event_data_2};
		}
	}
	if($sensor_type == 0x12) {
		if($offset == 0x03) {
		}
		if($offset == 0x04) {
			my %extra = (
				0x00 => "Alert",
				0x01 => "power off",
				0x02 => "reset",
				0x04 => "power cycle",
				0x08 => "OEM action",
				0x10 => "NMI",
			);
			if($event_data_2 & 0b00100000) {
				$text = "$text, NMI";
			}
			if($event_data_2 & 0b00010000) {
				$text = "$text, OEM action";
			}
			if($event_data_2 & 0b00001000) {
				$text = "$text, power cycle";
			}
			if($event_data_2 & 0b00000100) {
				$text = "$text, reset";
			}
			if($event_data_2 & 0b00000010) {
				$text = "$text, power off";
			}
			if($event_data_2 & 0b00000001) {
				$text = "$text, Alert";
			}
			$text =~ s/^, //;
		}
	}

	return($text);
}

sub checkleds {
	my $netfun = 0xe8; #really 0x3a
	my @cmd;
	my @returnd = ();
	my $error;
	my $led_id_ms;
	my $led_id_ls;
	my $rc = 0;
	my @output =();
	my $text="";
	my $key;
	my $mfg_id;
	my $prod_id;
	($rc,$text,$mfg_id,$prod_id) = getdevid();
	if ($mfg_id != 2) {
		return (0,"LED status not supported on this system");
	}
	
	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}
	foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
		my $sdr = $sdr_hash{$key};
		if($sdr->sensor_type == 0xED && $sdr->rec_type == 0xC0) {
			#this stuff is to help me build the file from spec paste
			#my $tehstr=sprintf("grep 0x%04X /opt/xcat/lib/x3755led.tab",$sdr->led_id);
			#my $tehstr=`$tehstr`;
			#$tehstr =~ s/^0x....//;
			
			#printf("%X.%X.0x%04x",$mfg_id,$prod_id,$sdr->led_id);
			#print $tehstr;
		
			#We are inconsistant in our spec, first try a best guess
			#at endianness, assume the smaller value is MSB
			if (($sdr->led_id&0xff) > ($sdr->led_id>>8)) {
				$led_id_ls=$sdr->led_id&0xff;
				$led_id_ms=$sdr->led_id>>8;
			} else {	
				$led_id_ls=$sdr->led_id>>8;
				$led_id_ms=$sdr->led_id&0xff;
			}
				
			@cmd=(0xc0,$led_id_ms,$led_id_ls);
			$error = docmd(
				$netfun,
				\@cmd,
				\@returnd
			);
			if($error) {
				$rc = 1;
				$text = $error;
				return($rc,$text);
			}
			if ($returnd[36-$authoffset] == 0xc9) {
				my $tmp;
				#we probably guessed endianness wrong.
				$tmp=$led_id_ls;
				$led_id_ls=$led_id_ms;
				$led_id_ms=$tmp;
				@cmd=(0xc0,$led_id_ms,$led_id_ls);
				$error = docmd(
                                	$netfun,
					\@cmd,
					\@returnd
                       		);
				if($error) {
					$rc = 1;
					$text = $error;
					return($rc,$text);
				}
			}

			if ($returnd[38-$authoffset] != 0) {
				#It's on...
				if ($returnd[42-$authoffset] == 4) {
					push(@output,sprintf("BIOS or admininstrator has %s lit",getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds")));
				}
				elsif ($returnd[42-$authoffset] == 3) {
					push(@output,sprintf("A user has manually requested LED 0x%04x (%s) be active",$sdr->led_id,getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds")));
				}
				elsif ($returnd[42-$authoffset] == 1 && $sdr->led_id !=0) {
					push(@output,sprintf("LED 0x%02x%02x (%s) active to indicate LED 0x%02x%02x (%s) is active",$led_id_ms,$led_id_ls,getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds"),$returnd[40-$authoffset],$returnd[41-$authoffset],getsensorname($mfg_id,$prod_id,($returnd[40-$authoffset]<<8)+$returnd[41-$authoffset],"ibmleds")));
				}
				elsif ($sdr->led_id ==0) {
					push(@output,sprintf("LED 0x0000 (%s) active to indicate system error condition.",getsensorname($mfg_id,$prod_id,$sdr->led_id,"ibmleds")));
				}
				elsif ($returnd[42-$authoffset] == 2) {
					my $sensor_desc;
					#Ok, LED is tied to a sensor..
					my $sensor_num=$returnd[41-$authoffset];
				        foreach $key (keys %sdr_hash) {
						my $osdr = $sdr_hash{$key};
				                if($osdr->sensor_number == $sensor_num) {
				                        $sensor_desc = $sdr_hash{$key}->id_string;
				                        if($osdr->rec_type == 0x01) {
			                                	last;
							}
			                        }
			                }
					$rc=0;
					#push(@output,sprintf("Sensor 0x%02x (%s) has activated LED 0x%04x",$sensor_num,$sensor_desc,$sdr->led_id));
					push(@output,sprintf("LED 0x%02x%02x active to indicate Sensor 0x%02x (%s) error.",$led_id_ms,$led_id_ls,$sensor_num,$sensor_desc));
			        }
			} 
					
		}
	}
	if ($#output==-1) {
		push(@output,"No active error LEDs detected");
	}
	return($rc,@output);
}
	
sub vitals {
	my $subcommand = shift;

	my $rc = 0;
	my $text;
	my $key;
	my @sensor_filters=(0x00);
	my @output;
	my $reading;
	my $unitdesc;
	my $value;
	my $format = "%-30s%8s %-20s";
	my $per = " ";
   my $doall;
   $doall=0;
	$rc=0;

	if($subcommand eq "all") {
		@sensor_filters=(0x01); #,0x02,0x03,0x04);
      $doall=1;
	}
	elsif($subcommand =~ /temp/) {
		@sensor_filters=(0x01);
	}
	elsif($subcommand eq "voltage") {
		@sensor_filters=(0x02);
	}
    elsif($subcommand =~ /watt/) {
        @sensor_filters=(0x03);
    }
	elsif($subcommand eq "fanspeed") {
		@sensor_filters=(0x04);
	}
	elsif($subcommand eq "power") {
		($rc,$text) = power("stat");
		$text = sprintf($format,"Power Status:",$text);
		return($rc,$text);
	}
	elsif($subcommand eq "leds") {
		my @cleds;
		($rc,@cleds) = checkleds();
		foreach $text (@cleds) {
			push(@output,$text);
		}
	}
	else {
		return(1,"unsupported command vitals $subcommand");
	}

	($rc,$text) = initsdr();
	if($rc != 0) {
		return($rc,$text);
	}

	foreach(@sensor_filters) {
		my $filter = $_;

		foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
			my $sdr = $sdr_hash{$key};
			if(($doall and not $sdr->sensor_type==0xed) or ($sdr->sensor_type == $filter && $sdr->rec_type == 0x01)) {
				my $lformat = $format;

				($rc,$reading) = readsensor($sdr->sensor_number);
				$unitdesc = "";
				if($rc == 0) {
					$unitdesc = $units{$sdr->sensor_units_2};

					$value = (($sdr->M * $reading) + ($sdr->B * (10**$sdr->B_exp))) * (10**$sdr->R_exp);
					if($sdr->linearization == 0) {
						$reading = $value;
						if($value == int($value)) {
							$lformat = "%-30s%8d%-20s";
						}
						else {
							$lformat = "%-30s%8.3f%-20s";
						}
					}
					elsif($sdr->linearization == 7) {
						if($value > 0) {
							$reading = 1/$value;
						}
						else {
							$reading = 0;
						}
						$lformat = "%-30s%8d %-20s";
					}
					else {
						$reading = "RAW($sdr->linearization) $reading";
					}
	
					if($sdr->sensor_units_1 & 1) {
						$per = "% ";
					} else {
                  $per = " ";
               }
               my $numformat = ($sdr->sensor_units_1 & 0b11000000) >> 6;
               if ($numformat) {
                  if ($numformat eq 0b11)  {
                     #Not sure what to do here..
                  } else {
                     if ($reading & 0b10000000) {
                        if ($numformat eq 0b01) {
                           $reading = 0-((~($reading&0b01111111))&0b1111111);
                        } elsif ($numformat eq 0b10) {
                           $reading = 0-(((~($reading&0b01111111))&0b1111111)+1);
                        }
                     }
                  }
               }
	
                    if($unitdesc eq "Watts") {
                        my $f = ($reading * 3.413);
                        $unitdesc = "Watts (".int($f+.5)." BTUs/hr)";
                    }
					if($unitdesc eq "C") {
						my $f = ($reading * 9/5) + 32;
						$unitdesc = "C (" . int($f + .5) . " F)";
					}
					if($unitdesc eq "F") {
						my $c = ($reading - 32) * 5/9;
						$unitdesc = "F (" . int($c + .5) . " C)";
					}
				}
            #$unitdesc.= sprintf(" %x",$sdr->sensor_type);
				$text = sprintf($lformat,$sdr->id_string . ":",$reading,$per.$unitdesc);
				push(@output,$text);
			}
#			else {
#				printf("%x %s %d\n",$sdr->sensor_number,$sdr->id_string,$sdr->sensor_type);
#			}
		}
	}

	if($subcommand eq "all") {
		my @cleds;
		($rc,$text) = power("stat");
		$text = sprintf($format,"Power Status:",$text);
		push(@output,$text);
		($rc,@cleds) = checkleds();
		foreach $text (@cleds) {
			push(@output,$text);
		}
	}

	return($rc,@output);
}

sub readsensor {
	my $sensor = shift;
	my $netfun = 0x10;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x2d,$sensor);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];
	if($code != 0x00) {
		$rc = 1;
		$text = $codes{$code};

		if(!$text) {
			$text = sprintf("unknown response %02x",$code);
		}
		chomp $text;

		return($rc,$text);
	}
	
	if ($returnd[38-$authoffset] & 0x20) {
		$rc = 1;
		$text = "N/A";
		return($rc,$text);
	}
	$text = $returnd[37-$authoffset];

	return($rc,$text);
}

sub initsdr {
	my $netfun;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	my $sdr_rep_info = SDR_rep_info->new();

	my $resv_id_ls;
	my $resv_id_ms;
	my $nrid_ls = 0;
	my $nrid_ms = 0;
	my $rid_ls = 0;
	my $rid_ms = 0;
	my $sdr_ver;
	my $sdr_type;
	my $sdr_offset;
	my $sdr_len;
	my @sdr_data = ();
	my $offset;
	my $len;
	my $i;
#	my $numbytes = 27;
	my $numbytes = 22;
	my $override_string;
	my $ipmisensortab = "$ENV{XCATROOT}/lib/GUMI/ipmisensor.tab";
	my $byte_format;
	my $cache_file;

	my $mfg_id;
	my $prod_id;
	my $device_id;
	my $dev_rev;
	my $fw_rev1;
	my $fw_rev2;

	($rc,$text,$mfg_id,$prod_id,$device_id,$dev_rev,$fw_rev1,$fw_rev2) = getdevid();
	if($rc != 0) {
		return($rc,$text);
	}

	$cache_file = "$cache_dir/sdr_$mfg_id.$prod_id.$device_id.$dev_rev.$fw_rev1.$fw_rev2.$cache_version";
	if($enable_cache eq "yes") {
		$rc = loadsdrcache($cache_file);
		if($rc == 0) {
			return($rc);
		}
		$rc = 0;
	}

	($rc,$text) = get_sdr_rep_info($sdr_rep_info);
	if($rc != 0) {
		return($rc,$text);
	}

	if($sdr_rep_info->version != 0x51) {
		$rc = 1;
		$text = "SDR version 51h support only.";
		return($rc,$text);
	}

	if($sdr_rep_info->resv_sdr != 1) {
		$rc = 1;
		$text = "SDR reservation unsupported.";
		return($rc,$text);
	}

	($rc,$text,$resv_id_ls,$resv_id_ms) = resv_sdr_repo();
	if($rc != 0) {
		return($rc,$text);
	}

	if($debug) {
		print "mfg,prod,dev: $mfg_id, $prod_id, $device_id\n";
		printf("SDR info: %02x %d %d\n",$sdr_rep_info->version,$sdr_rep_info->rec_count,$sdr_rep_info->resv_sdr);
		print "resv_id: $resv_id_ls $resv_id_ms\n";
	}

	foreach(1..$sdr_rep_info->rec_count) {
		$netfun = 0x28;
		@cmd = (0x23,$resv_id_ls,$resv_id_ms,$nrid_ls,$nrid_ms,0,5);
		$error = docmd(
			$netfun,
			\@cmd,
			\@returnd
		);

		if($error) {
			$rc = 1;
			$text = $error;
			return($rc,$text);
		}

		$code = $returnd[36-$authoffset];
		if($code != 0x00) {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
###x336 hack
		$rid_ls = $nrid_ls;
		$rid_ms = $nrid_ms;
###
		$nrid_ls = $returnd[37-$authoffset];
		$nrid_ms = $returnd[38-$authoffset];
### correct IPMI code
#		$rid_ls = $returnd[39-$authoffset];
#		$rid_ms = $returnd[40-$authoffset];
###
		$sdr_ver = $returnd[41-$authoffset];
		$sdr_type = $returnd[42-$authoffset];
		$sdr_len = $returnd[43-$authoffset] + 5;

		if($sdr_type == 0x01) {
			$sdr_offset = 0;
		}
		elsif($sdr_type == 0x02) {
			$sdr_offset = 16;
		}
		elsif($sdr_type == 0xC0) {
			#LED descriptor, maybe
		}
		elsif($sdr_type == 0x12) {
			next;
		}
		else {
			next;
		}

		@sdr_data = (0,0,0,$sdr_ver,$sdr_type,$sdr_len);
		$offset = 5;
		for($i=5;$i<$sdr_len;$i+=$numbytes) {
			$len = $numbytes;
			if($offset+$len > $sdr_len) {
				$len = $sdr_len - $offset;
			}

			@cmd = (0x23,$resv_id_ls,$resv_id_ms,$rid_ls,$rid_ms,$offset,$len);
			$error = docmd(
				$netfun,
				\@cmd,
				\@returnd
			);

			if($error) {
				$rc = 1;
				$text = $error;
				return($rc,$text);
			}

			$code = $returnd[36-$authoffset];
			if($code != 0x00) {
				$rc = 1;
				$text = $codes{$code};
				if(!$text) {
					$rc = 1;
					$text = sprintf("unknown response %02x",$code);
				}
				return($rc,$text);
			}

			@sdr_data = (@sdr_data,@returnd[39-$authoffset..@returnd-2]);

			$offset += $len;
		}

		if($debug) {
			hexadump(\@sdr_data);
		}
		if($sdr_type == 0x12) {
			hexadump(\@sdr_data);
			next;
		}

		my $sdr = SDR->new();

		if ($mfg_id == 2 && $sdr_type==0xC0 && $sdr_data[9] == 0xED) {
			#printf("%02x%02x\n",$sdr_data[13],$sdr_data[12]);
			$sdr->rec_type($sdr_type);
			$sdr->sensor_type($sdr_data[9]);
			#Using an impossible sensor number to not conflict with decodealert
			$sdr->sensor_owner_id(260);
			$sdr->sensor_owner_lun(260);
			if ($sdr_data[12] > $sdr_data[13]) {
				$sdr->led_id(($sdr_data[13]<<8)+$sdr_data[12]);
			} else {
				$sdr->led_id(($sdr_data[12]<<8)+$sdr_data[13]);
			}
			#$sdr->led_id_ms($sdr_data[13]);
			#$sdr->led_id_ls($sdr_data[12]);
			$sdr->sensor_number(sprintf("%04x",$sdr->led_id));
			#printf("%02x,%02x,%04x\n",$mfg_id,$prod_id,$sdr->led_id);	
			#Was going to have a human readable name, but specs
			#seem to not to match reality...
			#$override_string = getsensorname($mfg_id,$prod_id,$sdr->sensor_number,$ipmiledtab);
			#I'm hacking in owner and lun of 260 for LEDs....
			$sdr_hash{"260.260.".$sdr->led_id} = $sdr;
			next;
		}


		$sdr->rec_type($sdr_type);
		$sdr->sensor_owner_id($sdr_data[6]);
		$sdr->sensor_owner_lun($sdr_data[7]);
		$sdr->sensor_number($sdr_data[8]);
		$sdr->entity_id($sdr_data[9]);
		$sdr->entity_instance($sdr_data[10]);
		$sdr->sensor_type($sdr_data[13]);
		$sdr->event_type_code($sdr_data[14]);
		$sdr->sensor_units_2($sdr_data[22]);
		$sdr->sensor_units_3($sdr_data[23]);

		if($sdr_type == 0x01) {
		   $sdr->sensor_units_1($sdr_data[21]);
			$sdr->linearization($sdr_data[24] & 0b01111111);
			$sdr->M(comp2int(10,(($sdr_data[26] & 0b11000000) << 2) + $sdr_data[25]));
			$sdr->B(comp2int(10,(($sdr_data[28] & 0b11000000) << 2) + $sdr_data[27]));
			$sdr->R_exp(comp2int(4,($sdr_data[30] & 0b11110000) >> 4));
			$sdr->B_exp(comp2int(4,$sdr_data[30] & 0b00001111));
		} elsif ($sdr_type == 0x02) {
		   $sdr->sensor_units_1($sdr_data[21]);
      }

		$sdr->id_string_type($sdr_data[48-$sdr_offset]);

		$override_string = getsensorname($mfg_id,$prod_id,$sdr->sensor_number,$ipmisensortab);

		if($override_string ne "") {
			$sdr->id_string($override_string);
		}
		else {
			$byte_format = ($sdr->id_string_type & 0b11000000) >> 6;
			if($byte_format == 0b11) {
				my $len = ($sdr->id_string_type & 0b00011111) - 1;
				if($len > 1) {
					$sdr->id_string(pack("C*",@sdr_data[49-$sdr_offset..49-$sdr_offset+$len]));
				}
				else {
					$sdr->id_string("no description");
				}
			}
			elsif($byte_format == 0b10) {
				$sdr->id_string("ASCII packed unsupported");
			}
			elsif($byte_format == 0b01) {
				$sdr->id_string("BCD unsupported");
			}
			elsif($byte_format == 0b00) {
				$sdr->id_string("unicode unsupported");
			}
		}

		$sdr_hash{$sdr->sensor_owner_id . "." . $sdr->sensor_owner_lun . "." . $sdr->sensor_number} = $sdr;
	}

	if($debug) {
		my $key;
#		foreach $key (sort {$sdr_hash{$a}->sensor_number <=> $sdr_hash{$b}->sensor_number} keys %sdr_hash) {
		foreach $key (sort {$sdr_hash{$a}->id_string cmp $sdr_hash{$b}->id_string} keys %sdr_hash) {
			my $sdr = $sdr_hash{$key};
#			printf("%d %x %s\n",$sdr->rec_type,$sdr->sensor_number,$sdr->id_string);
#			printf("%x %x %x %s\n",$sdr->sensor_owner_id,$sdr->sensor_owner_lun,$sdr->sensor_number,$sdr->id_string);
			printf("%x %x %x %s %d\n",$sdr->sensor_owner_id,$sdr->sensor_owner_lun,$sdr->sensor_number,$sdr->id_string,$sdr->linearization);
		}
#		printf("\n%x %s\n",$sdr_hash{0x70}->sensor_number,$sdr_hash{0x70}->id_string);
	}

	if($enable_cache eq "yes") {
		storsdrcache($cache_file);
	}

	return($rc,$text);
}

sub getsensorname
{
	my $mfgid = shift;
	my $prodid = shift;
	my $sensor = shift;
	my $file = shift;

	my $mfg;
	my $prod;
	my $type;
	my $num;
	my $desc;
	my $name="";

    if ($file eq "ibmleds") {
            if ($xCAT::data::ibmleds::leds{"$mfgid,$prodid"}->{$sensor}) {
              return $xCAT::data::ibmleds::leds{"$mfgid,$prodid"}->{$sensor}. " LED";
            } elsif ($ndebug) {
              return "Unknown $sensor/$mfgid/$prodid";
            } else {
              return sprintf ("LED 0x%x",$sensor);
            }
    } else {
      return "";
    }
}

sub getchassiscap {
	my $netfun = 0x00;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x00);
	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}

	$code = $returnd[36-$authoffset];
	if($code == 0x00) {
		$text = "";
	}
	else {
		$rc = 1;
		$text = $codes{$code};
		if(!$text) {
			$rc = 1;
			$text = sprintf("unknown response %02x",$code);
		}
		return($rc,$text);
	}

	return($rc,@returnd[37-$authoffset..@returnd-2]);
}

sub getdevid {
	my $netfun = 0x18;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x01);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	my $device_id = $returnd[37-$authoffset];
	my $device_rev = $returnd[38-$authoffset] & 0b00001111;
	my $firmware_rev1 = $returnd[39-$authoffset] & 0b01111111;
	my $firmware_rev2 = $returnd[40-$authoffset];
	my $ipmi_ver = $returnd[41-$authoffset];
	my $dev_support = $returnd[42-$authoffset];
	my $sensor_device = 0;
	my $SDR = 0;
	my $SEL = 0;
	my $FRU = 0;
	my $IPMB_ER = 0;
	my $IPMB_EG = 0;
	my $BD = 0;
	my $CD = 0;
	if($dev_support & 0b00000001) {
		$sensor_device = 1;
	}
	if($dev_support & 0b00000010) {
		$SDR = 1;
	}
	if($dev_support & 0b00000100) {
		$SEL = 1;
	}
	if($dev_support & 0b00001000) {
		$FRU = 1;
	}
	if($dev_support & 0b00010000) {
		$IPMB_ER = 1;
	}
	if($dev_support & 0b00100000) {
		$IPMB_EG = 1;
	}
	if($dev_support & 0b01000000) {
		$BD = 1;
	}
	if($dev_support & 0b10000000) {
		$CD = 1;
	}
	my $mfg_id = $returnd[43-$authoffset] + $returnd[44-$authoffset]*0x100 +  $returnd[45-$authoffset]*0x10000;
	my $prod_id = $returnd[46-$authoffset] + $returnd[47-$authoffset]*0x100;
	my @data = @returnd[48-$authoffset..@returnd-2];

	return($rc,$text,$mfg_id,$prod_id,$device_id,$device_rev,$firmware_rev1,$firmware_rev2);
}

sub getguid {
	my $guidcmd = shift;
	my $netfun = @$guidcmd[0] || 0x18;
	my @cmd = @$guidcmd[1] || 0x37;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	my @guid = @returnd[37-$authoffset..52-$authoffset];
	my $guidtext = sprintf("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",@guid);
	$guidtext =~ tr/[a-z]/[A-Z]/;

	return($rc,$text,$guidtext);
}

sub get_sdr_rep_info {
	my $sdr_rep_info = shift;

	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x20);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	$sdr_rep_info->version($returnd[37-$authoffset]);
	$sdr_rep_info->rec_count($returnd[38-$authoffset] + $returnd[39-$authoffset]*0x100);
	$sdr_rep_info->resv_sdr(($returnd[50-$authoffset] & 0b00000010) ? 1 : 0);

	return($rc,$text);
}

sub resv_sdr_repo {
	my $netfun = 0x28;
	my @cmd;
	my @returnd = ();
	my $error;
	my $rc = 0;
	my $text;
	my $code;

	@cmd = (0x22);

	$error = docmd(
		$netfun,
		\@cmd,
		\@returnd
	);

	if($error) {
		$rc = 1;
		$text = $error;
		return($rc,$text);
	}
	else {
		$code = $returnd[36-$authoffset];

		if($code == 0x00) {
			$text = "";
		}
		else {
			$rc = 1;
			$text = $codes{$code};
			if(!$text) {
				$rc = 1;
				$text = sprintf("unknown response %02x",$code);
			}
			return($rc,$text);
		}
	}

	my $resv_id_ls = $returnd[37-$authoffset];
	my $resv_id_ms = $returnd[38-$authoffset];

	return($rc,$text,$resv_id_ls,$resv_id_ms);
}

sub docmd {
	my $netfun = shift;
	my $cmd = shift;
	my $response = shift;

	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my @data;

	incseqlun();

	@data = ($rqsa,$seqlun,@$cmd);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	incseqnum();

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@$response) = domsg($sock,\@msg,$timeout,1);

	return($error);
}

sub getchanauthcap {
	$auth = 0x00;
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my $error = "";
	my @response;
	my $code;

	@data = ($rqsa,$seqlun,0x38,0x0e,0x04);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	
	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		$length,
		$rssa,
		$netfun,
		dochksum(\@rn),
		@data,
		dochksum(\@data)
	);

	($error,@response) = domsg($sock,\@msg,$timeout,0);

	if($error) {
		return($error);
	}

	$code = $response[20];
	if($code != 0x00) {
		$error = $codes{$code};
		if(!$error) {
			$error = "Unknown get channel authentication capabilities error $code"
		}
		return($error);
	}

	$channel_number=$response[21];

	if($response[22] & 0b10000000) {
		$ipmiv2=1;
	}
	if($response[22] & 0b00000100) {
		$auth=0x02;
	}
	elsif($response[22] & 0b00010000) {
		$auth=0x04;
	}
	else {
		$error = "unsupported Authentication Type Support";
	}

	return($error);
}

sub getsessionchallenge {
	my $tauth = 0x00;
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x39,$auth,@user);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	
	@msg = (
		@rmcp,
		$tauth,
		@seqnum,
		@session_id,
		$length,
		$rssa,
		$netfun,
		dochksum(\@rn),
		@data,
		dochksum(\@data)
	);

	($error,@response) = domsg($sock,\@msg,$timeout,0);

	if(!$error) {
		$code = $response[20];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown get session challenge error $code"
			}
		}

		if($code == 0x81) {
			$error = "Invalid user name";
		}
		elsif($code == 0x82) {
			$error = "null user name not enabled";
		}

		@session_id = @response[21,22,23,24];

    	for (my $i=0;$i<16;$i++){
			$challenge[$i] = $response[25+$i];
    	}
	}

	return($error);
}

sub activatesession {
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x3A,$auth,0x04,@challenge,0x01,0x00,0x00,0x00);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@response) = domsg($sock,\@msg,$timeout,0);

	if(!$error) {
		$code = $response[36];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown activate session error $code"
			}
		}

		if($code == 0x81) {
			$error = "No session slot available";
		}
		elsif($code == 0x82) {
			$error = "No slot available for given user";
		}
		elsif($code == 0x83) {
			$error = "No slot available to support user due to maximum privilege capability";
		}
		elsif($code == 0x84) {
			$error = "Session sequence number out-of-range";
		}
		elsif($code == 0x85) {
			$error = "Invalid session ID in request";
		}
		elsif($code == 0x86) {
			$error = "Requested maximum privilege level exceeds user and/of channel privilege limit";
		}

		$auth = $response[37];
		if($auth == 0x00) {
			$authoffset=16;
		}
		elsif($auth == 0x02) {
		}
		elsif($auth == 0x04) {
		}
		else {
			$error = "activate session requested unsupported Authentication Type Support";
		}

###check
		@session_id = @response[38,39,40,41];
		@seqnum = @response[42,43,44,45];
	}

	return($error);
}

sub setprivlevel()
{
	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x3B,0x04);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@response) = domsg($sock,\@msg,$timeout,1);

	if(!$error) {
		$code = $response[36-$authoffset];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown set session privilege level error $code"
			}
		}

		if($code == 0x80) {
			$error = "Requested level not available for this user";
		}
		elsif($code == 0x81) {
			$error = "Requested level exceeds channel and/or user privilege limit";
		}
		elsif($code == 0x82) {
			$error = "Cannot disable user level authentication";
		}
	}

	return($error);
}

sub closesession()
{
	incseqnum();

	my $netfun = 0x18;
	my @data;
	my @rn;
	my $length;

	my @msg;
	my @message;
	my $error = "";
	my @response;
	my $code;

	incseqlun();

	@data = ($rqsa,$seqlun,0x3C,@session_id);
	@rn = ($rssa,$netfun);
	$length = (scalar @data)+4;
	@message = ($rssa,$netfun,dochksum(\@rn),@data,dochksum(\@data));

	@msg = (
		@rmcp,
		$auth,
		@seqnum,
		@session_id,
		authcode(2,\@message),
		$length,
		@message
	);

	($error,@response) = domsg($sock,\@msg,$timeout,1);

	if(!$error) {
		$code = $response[36-$authoffset];
		if($code != 0x00) {
			$error = $codes{$code};
			if(!$error) {
				$error = "Unknown close session error $code"
			}
		}

		if($code == 0x87) {
			$error = "Invalid session ID in request";
		}
	}

	return($error);
}

sub domsg {
	my $sock = shift;
	my $msg = shift;
	my $timeout = shift;
	my $seq = shift || 0;
	my $debug = $localdebug;
	my $trys = $localtrys;
	my $send;
	my $quit = 0;
	my $error="";
	my $recv;
	my @response;
	my $timedout;
	my @foo;
	my @message;

	$send = pack('C*',@$msg);

	while($trys > 0) {
		$trys--;
		$error = "";
		$timedout = 0;

		if($debug) {
			print "try: $trys, timeout: $timeout\n";
		}

		if(!$sock->send($send)) {
			$error = $!;
			sleep(1);
			next;
		}
		my $s = IO::Select->new($sock);
		#local $SIG{ALRM} = sub { $timedout = 1 and die };
		#alarm($timeout);
		my $received = $s->can_read($timeout);
		if($received > 0) {
			if ($sock->recv($recv,128)) {
				if($recv) {
					@response = unpack("C*",$recv);
					last;
				}
			} else {
				$error = $!;
			}
		}
		else {
			$error = "timeout";
		}

###ugly updated hack to support md5.
		if($seq) {
			incseqnum();

			@$msg[5..8] = @seqnum[0..3];
			@message = @$msg[30..@$msg-1];
			if($auth != 0x00) {
				@$msg[13..28] = authcode(2,\@message);
			}

			$send = pack('C*',@$msg);
		}
	}

	if($timedout == 1) {
		if($error) {
			$error = "timeout $error"
		}
		else {
			$error = "timeout"
		}
	}

	return($error,@response);
}

sub dochksum()
{
	my $data = shift;
	my $sum = 0;

	foreach(@$data) {
		$sum += $_;
	}

	$sum = ~$sum + 1;
	return($sum & 0xFF);
}

sub dopad16 {
	my @pad16 = unpack("C*",shift);	

	for(my $i=@pad16;$i<16;$i++) {
		$pad16[$i] = 0;
	}

	return(@pad16);
}

sub hexdump {
	my $data = shift;

	foreach(@$data) {
		printf("%02x ",$_);
	}
	print "\n";
}

sub getascii {
        my @alpha;
        my $text ="";
        my $c = 0;

        foreach(@_) {
                $alpha[$c] = sprintf("%c",$_);
                if($alpha[$c] !~ /[\/\w\-:]/) {
        			if ($alpha[($c-1)] !~ /\s/) {
                    	    $alpha[$c] = " ";
	          		} else {
			        	$c--;
			        }
                }
                $c++;
        }
        foreach(@alpha) {
                $text=$text.$_;
        }
	$text =~ s/^\s+|\s+$//;
	return $text;
}
sub phex {
        my $data = shift;
        my @alpha;
        my $text ="";
        my $c = 0;

        foreach(@$data) {
                $text = $text . sprintf("%02x ",$_);
                $alpha[$c] = sprintf("%c",$_);
                if($alpha[$c] !~ /\w/) {
                        $alpha[$c] = " ";
                }
                $c++;
        }
        $text = $text . "(";
        foreach(@alpha) {
                $text=$text.$_;
        }
        $text = $text . ")";
        return $text;
}

sub hexadump {
	my $data = shift;
	my @alpha;
	my $c = 0;

	foreach(@$data) {
		printf("%02x ",$_);
		$alpha[$c] = sprintf("%c",$_);
		if($alpha[$c] !~ /\w/) {
			$alpha[$c] = ".";
		}
		$c++;
		if($c == 16) {
			print "   ";
			foreach(@alpha) {
				print $_;
			}
			print "\n";
			@alpha=();
			$c=0;
		}
	}
	foreach($c..16) {
		print "   ";
	}
	foreach(@alpha) {
		print $_;
	}
	print "\n";
}

sub incseqnum {
	my $i;

	for($i = 0;$i < 4;$i++) {
		if($seqnum[$i] < 0xFF) {
			$seqnum[$i]++;
			last;
		}
		$seqnum[$i] = 0;
	}

	if($seqnum[3] > 0xFF) {
		@seqnum = (0,0,0,0);
	}
}

sub incseqlun {
	$seqlun += 4;

	if($seqlun > 0xFF) {
		$seqlun = 0;
	}
}

sub authcode {
	my $type = shift;
	my $message = shift;
	my @authcode;

	if($auth == 0x02) {
		if($type == 1) {
			@authcode = unpack("C*",md5(pack("C*",@pass,@session_id,@challenge,@pass)));
		}
		elsif($type == 2) {
			@authcode = unpack("C*",md5(pack("C*",@pass,@session_id,@$message,@seqnum,@pass)));
		}
	}
	elsif($auth == 0x04) {
		@authcode = @pass;
	}
	elsif($auth == 0x00) {
		@authcode = ();
	}

	return(@authcode);
}

sub comp2int {
	my $length = shift;
	my $bits = shift;
	my $neg = 0;

	if($bits & 2**($length - 1)) {
		$neg = 1;
	}

	$bits &= (2**($length - 1) - 1);

	if($neg) {
		$bits -= 2**($length - 1);
	}

	return($bits);
}

sub timestamp2datetime {
	my $ts = shift;
	my @t = localtime($ts);
	my $time = strftime("%H:%M:%S",@t);
	my $date = strftime("%m/%d/%Y",@t);

	return($date,$time);
}

sub decodebcd {
	my $numbers = shift;
	my @bcd;
	my $text;
	my $ms;
	my $ls;

	foreach(@$numbers) {
		$ms = ($_ & 0b11110000) >> 4;
		$ls = ($_ & 0b00001111);
		push(@bcd,$ms);
		push(@bcd,$ls);
	}

	foreach(@bcd) {
		if($_ < 0x0a) {
			$text .= $_;
		}
		elsif($_ == 0x0a) {
			$text .= " ";
		}
		elsif($_ == 0x0b) {
			$text .= "-";
		}
		elsif($_ == 0x0c) {
			$text .= ".";
		}
	}

	return($text);
}

sub storsdrcache {
	my $file = shift;
	my $key;
	my $fh;

	system("mkdir -p $cache_dir");
	if(!open($fh,">$file")) {
		return(1);
	}

	flock($fh,LOCK_EX) || return(1);

	foreach $key (keys %sdr_hash) {
		my $r = $sdr_hash{$key};
		store_fd($r,$fh);
	}

	close($fh);

	return(0);
}

sub loadsdrcache {
	my $file = shift;
	my $r;
	my $c=0;
	my $fh;

	if(!open($fh,"<$file")) {
		return(1);
	}

	flock($fh,LOCK_SH) || return(1);

	while() {
		eval {
			$r = retrieve_fd($fh);
		} || last;

		$sdr_hash{$r->sensor_owner_id . "." . $r->sensor_owner_lun . "." . $r->sensor_number} = $r;
	}

	close($fh);

	return(0);
}


sub preprocess_request { 
  my $request = shift;
  my @requests;
  my %servicenodehash;
  my %noservicenodehash;
  my $nrtab = xCAT::Table->new('noderes');
  foreach my $node (@{$request->{node}}) {
     my $tent  = $nrtab->getNodeAttribs($node,['servicenode']);
     if ($tent and $tent->{servicenode}) {
       $servicenodehash{$tent->{servicenode}}->{$node} = 1;
     } else {
       $noservicenodehash{$node} = 1;
      }
   }
   foreach my $smaster (keys %servicenodehash) {
  	   my $reqcopy = {%$request};
	   $reqcopy->{'_xcatdest'} = $smaster;
	   $reqcopy->{node} = [ keys %{$servicenodehash{$smaster}} ];
	   push @requests,$reqcopy;
   }
   my $reqcopy = {%$request};
   $reqcopy->{node} = [ keys %noservicenodehash ];
   if ($reqcopy->{node}) {
      push @requests,$reqcopy;
   }
   return \@requests;
}
    
     

     


   
sub process_request {
    my $request = shift;
    my $callback = shift;
	my $noderange = $request->{node}; #Should be arrayref
	my $command = $request->{command}->[0];
	my $extrargs = $request->{arg};
    my @exargs=($request->{arg});
    unless ($noderange) {
        if ($usage{$command}) {
            $callback->({data=>$usage{$command}});
            $request = {};
        }
        return;
    }
    if (ref($extrargs)) {
      @exargs=@$extrargs;
    }
	my $ipmiuser = 'USERID';
	my $ipmipass = 'PASSW0RD';
	my $ipmitrys = 3;
	my $ipmitimeout = 2;
	my $ipmimaxp = 64;
	my $sitetab = xCAT::Table->new('site');
	my $ipmitab = xCAT::Table->new('ipmi');
	my $tmp;
	if ($sitetab) {
		($tmp)=$sitetab->getAttribs({'key'=>'ipmimaxp'},'value');
		if (defined($tmp)) { $ipmimaxp=$tmp->{value}; }
		($tmp)=$sitetab->getAttribs({'key'=>'ipmitimeout'},'value');
		if (defined($tmp)) { $ipmitimeout=$tmp->{value}; }
		($tmp)=$sitetab->getAttribs({'key'=>'ipmiretries'},'value');
		if (defined($tmp)) { $ipmitrys=$tmp->{value}; }
		($tmp)=$sitetab->getAttribs({'key'=>'ipmisdrcache'},'value');
		if (defined($tmp)) { $enable_cache=$tmp->{value}; }
	}
	my $passtab = xCAT::Table->new('passwd');
	if ($passtab) {
		($tmp)=$passtab->getAttribs({'key'=>'ipmi'},'username','password');
		if (defined($tmp)) { 
			$ipmiuser = $tmp->{username};
			$ipmipass = $tmp->{password};
		}
	}

    #my @threads;
    my @donargs=();
	foreach(@$noderange) {
		my $node=$_;
		my $nodeuser=$ipmiuser;
		my $nodepass=$ipmipass;
		my $nodeip = $node;
		my $ent;
		if (defined($ipmitab)) {
			$ent=$ipmitab->getNodeAttribs($node,['bmc','username','password']) ;
			if (ref($ent) and defined $ent->{bmc}) { $nodeip = $ent->{bmc}; }
			if (ref($ent) and defined $ent->{username}) { $nodeuser = $ent->{username}; }
			if (ref($ent) and defined $ent->{password}) { $nodepass = $ent->{password}; }
		}
        push @donargs,[$node,$nodeip,$nodeuser,$nodepass];
    }
    my $children = 0;
    $SIG{CHLD} = sub {my $kpid; do { $kpid = waitpid(-1, WNOHANG); if ($kpid > 0) { $children--; } } while $kpid > 0; };
    my $sub_fds = new IO::Select;
    foreach (@donargs) {
      while ($children > $ipmimaxp) { sleep (0.1); }
      $children++;
      my $cfd;
      my $pfd;
      pipe $cfd, $pfd;
	  my $child = fork();
      unless (defined $child) { die "Fork failed" };
	  if ($child == 0) { 
        close($cfd);
        donode($pfd,$_->[0],$_->[1],$_->[2],$_->[3],$ipmitimeout,$ipmitrys,$command,-args=>\@exargs);
        close($pfd);
		exit(0);
	  }
      close ($pfd);
      $sub_fds->add($cfd)
	}
    while ($children > 0) {
      forward_data($callback,$sub_fds);
    }
    while (forward_data($callback,$sub_fds)) {} #Make sure they get drained, this probably is overkill but shouldn't hurt
}
sub forward_data { #unserialize data from pipe, chunk at a time, use magic to determine end of data structure
  my $callback = shift;
  my $fds = shift;
  my @ready_fds = $fds->can_read(1);
  my $rfh;
  my $rc = @ready_fds;
  foreach $rfh (@ready_fds) {
    my $data;
    if ($data = <$rfh>) {
      while ($data !~ /ENDOFFREEZE6sK4ci/) {
        $data .= <$rfh>;
      }
      my $responses=thaw($data);
      foreach (@$responses) {
        $callback->($_);
      }
    } else {
      $fds->remove($rfh);
      close($rfh);
    }
  }
  yield; #Avoid useless loop iterations by giving children a chance to fill pipes
  return $rc;
}

sub donode {
  my $outfd = shift;
  my $node = shift;
  my $bmcip = shift;
  my $user = shift;
  my $pass = shift;
  my $timeout = shift;
  my $retries = shift;
  my $command = shift;
  my %namedargs=@_;
  my $transid = $namedargs{-transid};
  my $extra=$namedargs{-args};
  my @exargs=@$extra;
  my ($rc,@output) = ipmicmd($bmcip,623,$user,$pass,$timeout,$retries,0,$command,@exargs);
  my @outhashes;
  foreach(@output) {
    my %output;
    (my $desc,my $text) = split(/:/,$_,2);
    unless ($text) {
      $text=$desc;
    } else {
      $desc =~ s/^\s+//;
      $desc =~ s/\s+$//;
      $output{node}->[0]->{data}->[0]->{desc}->[0]=$desc;
    }
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    $output{node}->[0]->{name}->[0]=$node;
    $output{node}->[0]->{data}->[0]->{contents}->[0]=$text;
    if ($rc) {
      $output{node}->[0]->{errorcode}=$rc;
    }
    #push @outhashes,\%output; #Save everything for the end, don't know how to be slicker with Storable and a pipe
    print $outfd freeze([\%output]);
    print $outfd "\nENDOFFREEZE6sK4ci\n";
  }	
  yield;
  #my $msgtoparent=freeze(\@outhashes);
 # print $outfd $msgtoparent;
}

1;
