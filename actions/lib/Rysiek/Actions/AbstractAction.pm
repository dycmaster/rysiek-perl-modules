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

	my $trackedMaster: shared;
	my $q = Thread::Queue->new();
	
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

		my $serviceType=config->{unitIdentifiers}{action};

		my $service = $publisher->publish(
			name => $self->name,
			type => config->{unitIdentifiers}{action},
			port => $self->port,
		);
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
		&initRequestsProcessor;
		&initMastersTrackingEngine;
		return 1;		
	}
	
	
	#there's a thread calling urls from the queue
	#this is used when one action wants to call some other actions
	sub initRequestsProcessor{
		my $thr = threads->create(
			sub{
				 while (defined(my $item = $q->dequeue())) {
					debug("Processing request: $item");
					my $res = LWP::Simple::get($item);
					
					if (! defined $res) {
						warn("calling get on $item was unsuccessful.");						
					}else{
						debug "request: $item, response: $res";
					}
				 }				
			}
		);		
		$thr->detach();		
		return 1;		
	}
	
	

	#There is always a hash kept in the instance of this class
	#storing address of currently available master.
	#This is to save time if one action want's to call other action quickly
	sub initMastersTrackingEngine{

		my %emptyHash : shared = ();
		$trackedMaster = \%emptyHash;

		my $thr = threads->create(\&trackMaster);
		$thr->detach();
		debug("Master tracking thread started.");

		return 1;
	}

	sub trackMaster{
		while (1) {
			my $zeroconfLink = &getBasicAvahiServiceLink;			
			$zeroconfLink = $zeroconfLink."service/master";
			my $res = LWP::Simple::get( $zeroconfLink);

			{
				lock($trackedMaster);
				%$trackedMaster=();

			if (defined $res) {
				my $yaml = YAML::Tiny->read_string( $res );
				my $firstMaster: shared;
				my %emptyHash : shared = ();
				$firstMaster = \%emptyHash;
				my $firstMastNonShared = $yaml->[0];
				my $masterName = (sort keys %$firstMastNonShared)[0];
				if (defined $masterName) {
					my $address = $firstMastNonShared->{$masterName}{address};
					my $port = $firstMastNonShared->{$masterName}{port};
					if (defined $address && defined $port) {
						my %data: shared = ();
						%data = (address=>$address, port=>$port);
						$firstMaster->{$masterName} = \%data;
						%$trackedMaster = %$firstMaster;						
					}
				}
			}
			}#lock			
			sleep(config->{masterTrackingInterval});
		}
		return 1;
	}

	sub getBasicAvahiServiceLink{
		my $avahiResolverData = &findAvahiUnits("avahi");	
		
		if (defined $avahiResolverData && (keys %$avahiResolverData > 0)) {
			my $avName = (sort keys %$avahiResolverData)[0];
			my $avData= $avahiResolverData->{$avName};
			my $host = $avData->{address};
			my $port = $avData->{port};

			my $link= "http://$host:$port/zeroconf/$avName/";
			return $link;
		}else{
			return "";
		}
	}


	#wrapper around `avahi-browse` utility
	sub findAvahiUnits{
		my $serviceTypeNameToFind = shift;
		my $serviceTypeToFind = config->{unitIdentifiers}{$serviceTypeNameToFind};

		my @value = qx(avahi-browse -cr $serviceTypeToFind);
		my ($inSensor, $hasName, $hasAddress, $hasPort);
		my ($sensorName, $sensorAddress, $sensorPort);

		my %sensorsLoc :shared;

		foreach(@value){

			if(!$inSensor){
				$inSensor = 1 if /^=/;
			}

			if($inSensor){
				if(!$sensorName){
					if(/=\s+\S+\s+\S+\s+(\S+)/xi){
						$sensorName = $1;
						next;
					}
				}

				if($sensorName){
					if(!$sensorAddress){
						if(/\s+address\s+=\s+\[(\S+)\]/xi){
							$sensorAddress = $1;
							next;
						}
					}
				}

				if($sensorName && $sensorAddress){
					if(!$sensorPort){
						if(/\s+port\s+=\s+\[(\S+)\]/xi){
							$sensorPort = $1;
						}
					}
				}

			}

			if($sensorName && $sensorAddress && $sensorPort){

				share($sensorsLoc{$sensorName});
				my %row :shared;
				%row = (address => $sensorAddress, port => $sensorPort);
				$sensorsLoc{$sensorName}= \%row;

				$sensorName = $sensorAddress = $sensorPort =0;
			}
		}

		return \%sensorsLoc;
	}





	#only masters can use actions directly
	#every action defines its allowed masters separately
	sub authorizeMaster{
		my $self = shift;
		my $mName = $self->name;
		my $cfg  = $self->actionConfig();
		my $knownMasters =  $cfg->[0]->{"knownMasters"};
		my $currMaster = params->{user};
		
		if (defined $currMaster){
			my $mastersToken = $cfg->[0]->{"mastersTokens"}{$currMaster};
			if (defined $mastersToken){
				if( (params->{user} ~~ @{$knownMasters}) && params->{token} eq  $mastersToken){
					debug ( params->{user}. " authorized successfuly in  $mName ");
					return 1;
				}
			}
		}

		debug ( params->{user}. " wrong credentials to action $mName. Sending 403.. ");
		send_error("Wrong credentials", 403);
		return 1;
	}

	1;
}
