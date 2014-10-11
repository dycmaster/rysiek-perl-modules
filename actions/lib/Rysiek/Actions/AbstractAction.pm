package Rysiek::Actions::AbstractAction 0.1{
	use 5.014;
	use Moose;
	use Dancer ':syntax';
	use YAML::Tiny;
	use Cwd 'abs_path';
	use Data::Dumper;
	use threads;
	use threads::shared;
	use HTTP::Request::Common;
	use LWP::UserAgent;
	use LWP::Simple qw(!get);
	use Thread::Queue;
  use Time::HiRes qw/time sleep /;

	my $trackedMaster: shared;
	my $q = Thread::Queue->new();
  our $zeroconfServiceLink: shared = "";

	
	#TODO - requests processor and master's tracker could be put into 1 thread

	my $configExt = '.yml';

	has "port" => (
		is  => "ro",
		isa => "Str",
		required => 1,
	);

	has "name" =>(
		is => "ro",
		isa => "Str",
		required =>1,
	);

	has "actionConfig" =>(
		is => "ro",

		default => sub{
			my $self = shift;
			my $obj_type = ref $self;
			my $fullPath=abs_path($0);
			$fullPath =~ s{bin/app.pl}{}g;
			my $configPath = $fullPath .'lib/' . ($obj_type =~ s{::}{/}gr) . $configExt;
			my $config = YAML::Tiny->read($configPath);
			$config;
		}
	);

	sub printConfig {
		my $self = shift;
		print Dumper( $self->{actionConfig});
	}

	sub init{
		my $self = shift;
		debug ("Init started for action: ". ref $self);

		$self->initAvahi;
		debug ("Avahi done for action ". ref $self);

		$self->initPaths;
		debug ("Paths done for action". ref $self);

		debug("Init finished for action: ". ref $self);
	}


	sub initAvahi{
		my $self = shift;
		use Net::Rendezvous::Publish;
		my $publisher = Net::Rendezvous::Publish->new
			or die "couldn't make a Publisher object";
		my $serviceType=config->{actionServiceAvahiType};
    debug"my avahi service type is $serviceType";
		my $service = $publisher->publish(
			name => $self->name,
			type => $serviceType,
			port => $self->port,
		);
    debug "Avahi published successfully";
		return 1;
	}



	sub initPaths{
		my $self = shift;
		my $mName = $self->name;
		my $cfg  = $self->actionConfig();

		#to do the action, user and token required
		get "/actions/".$mName ."/do" => sub {
			if($self->authorizeMaster() ){
				return  $self->doAction;
			}
		};

    post "/actions/" . $mName  . "/zeroconf" => sub {
      if($self->authorizeZeroconfService){
        return "port not defined" unless defined params->{port};

        my $ip = request->remote_address;
        my $port = params->{port};
        my $name = params->{user};
        my $link = "http://$ip:$port/zeroconf/$name/";

        say"I will ping the zeroconf now using: $link";
        my $pingRes = LWP::Simple::get( $link . "ping" );
        say "pinged ok";
        {
          lock ($zeroconfServiceLink);
          $zeroconfServiceLink="";
          if ( defined $pingRes && $pingRes ne "pong" ) {
            debug "zeroconf service alive but doesn't reply properly!";
          }
          elsif ( !defined $pingRes ) {
            debug("zeroconf service not available with link $link");
          }else{
            if( ! defined $zeroconfServiceLink || $zeroconfServiceLink eq "" ||
            $zeroconfServiceLink ne $link){
              debug("link $link replies to ping and it will be new zeroconf link");
              $zeroconfServiceLink=$link;
            }
          }
        }
      }
    };
		debug("paths from superclass done");
		return 1;
	}

	#prepares a link and enqueues it in a blocking queue
	sub callActionViaMaster{
		my $self = shift;
		my $actionName = shift;
		my $actionParam = shift;
		
		my $masterBasicLink = &getBasicMasterLinkFromProperty;
		my $user = config->{actionUserLogin};
		my $token = config->{actionUserPassword};	
		
		if (! defined $masterBasicLink) {
			warn("Master not available!!");
			return -1;
		}
		
		$masterBasicLink = $masterBasicLink."action/".$actionName."?user=$user&token=$token";
		
		if (defined $actionParam) {
			$masterBasicLink = $masterBasicLink. "&addParams=$actionParam"
		}
		
		if ($masterBasicLink) {
			$q->enqueue($masterBasicLink);
			return 1;
		}else{
			return -1;
		}
	}
	
	sub getBasicMasterLinkFromProperty{
		{
			lock($trackedMaster);
			if ((keys %$trackedMaster)>0) {
				my $masterName =  (sort keys %$trackedMaster)[0];
				my $masterHost = $trackedMaster->{$masterName}{address};
				my $masterPort = $trackedMaster->{$masterName}{port};
				
				return "http://$masterHost:$masterPort/masters/$masterName/";				
			}
		}
		return ;
	}

	sub initStatic{
    my %emptyHash: shared = ();
    $trackedMaster = \%emptyHash;
    &initWorkerThread;
		return 1;		
	}

  sub initWorkerThread{
    say "creating worker..";
    my $worker = threads->create(
      sub{
        $|=1;
        sleep 5;
        say "worker is rolling";
        my($lastWorkerStart, $lastMasterTrackTime) = (time, time);
        my $masterTrackFreq = config->{masterTrackingInterval};
        my $workerPeriod = config->{workerPeriod};

        while(1){
         $lastWorkerStart = time;
         
         &handleGetsFromQ;

         if(time - $lastMasterTrackTime >= $masterTrackFreq){
           &trackMaster;
           $lastMasterTrackTime = time;
         }

         my $elapsed = (time - $lastWorkerStart) * 1000;
         if( $elapsed < $workerPeriod){
           my $timeToSleep = ($workerPeriod - $elapsed) / 1000;
           sleep $timeToSleep;
         }
        }
      }
    );
    say "detaching worker";
    $worker->detach();
    return 1;
  }
	
	
	#there's a thread calling urls from the queue
	#this is used when one action wants to call some other actions
  sub handleGetsFromQ{
    while( $q->pending() > 0){
      my $item = $q->dequeue();
      debug("Processing request: $item");
      my $res = LWP::Simple::get($item);

      if (! defined $res) {
        warn("calling get on $item was unsuccessful.");						
      }else{
        debug "request: $item, response: $res";
      }
    }
    return 1;		
  }
  
  sub trackMaster{
    $|=1;
    {
      lock($trackedMaster);
      delete @$trackedMaster{keys %$trackedMaster};

      my $avMasters = &findUnits(config->{masterService});

      my $masterName = (sort keys %$avMasters)[0];
      if (defined $masterName && $masterName ne "") {
        my $address = $avMasters->{$masterName}{address};
        my $port = $avMasters->{$masterName}{port};
        if (defined $address && defined $port) {
          my %data: shared = ();
          %data = (address=>$address, port=>$port);
          $trackedMaster->{$masterName} = \%data;						
        }
      }
    }#lock			
  }
  
  sub findUnits{
    my $toFind = shift;
    my $zeroconfLink = &getBasicAvahiServiceLink;
    debug "zeroconf not defined!" unless defined $zeroconfLink;
    my $link = $zeroconfLink . "service/$toFind";
    debug "a link to find units of type $toFind is $link";
    my $zeroconfRes = LWP::Simple::get($link);
    debug"zeroconf service queried";

    my %result=();
    if ( defined $zeroconfRes ) {
      my $returnedYaml    = YAML::Tiny->read_string($zeroconfRes);

      if ( defined $returnedYaml->[0] ) {
        foreach my $unit (keys %{$returnedYaml->[0]}){
          my $address = $returnedYaml->[0]->{$unit}{address};
          my $port    = $returnedYaml->[0]->{$unit}{port};
          $result{$unit}={address=>$address, port=> $port };
        }
      }
    }
    #say " found units of type $toFind are:". Dumper(\%result) ;
    return \%result;
  }

  sub getBasicAvahiServiceLink {
    {
      lock $zeroconfServiceLink;
      return $zeroconfServiceLink;
    }
  }

	#only masters can use actions directly
	#every action defines its allowed masters separately
	sub authorizeMaster{
		my $self = shift;
    $self->checkCredentials("knownMasters", "mastersTokens");
	}
  
  sub authorizeZeroconfService{
    my $self = shift;
    $self->checkCredentials("knownZeroconfs", "zeroconfTokens");
  }

  sub checkCredentials {
    my $self      = shift;
    my $usersBase = shift;
    my $passBase  = shift;
    my $mName     = $self->name;
    my $user      = params->{user};
    my $token     = params->{token};

#debug ("$user is trying to authorize in $mName with token $token. Request path: ". request->path_info);

    if ( defined $user && defined $token ) {
      if ( $user ~~ config->{$usersBase} ) {
        if ( $token eq config->{$passBase}{$user} ) {

          #debug ("$user authorized successfuly in $mName ");
          return 1;
        }
      }
    }

    debug("$user wrong credentials to  $mName. Sending 403.. ");
    send_error( "Wrong credentials", 403 );
    1;
  }

	1;
}
