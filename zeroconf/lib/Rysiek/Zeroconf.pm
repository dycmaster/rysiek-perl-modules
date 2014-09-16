package Rysiek::Zeroconf 0.01{
        use warnings;
        use strict;
        use 5.014;
        use Moose;
        use Socket;
        use Dancer ':syntax';
        use Data::Dumper;
        use threads;
        use threads::shared;
        use HTTP::Request::Common;
        use LWP::UserAgent;
        use LWP::Simple qw(!get);


        has "name" =>(
                is => "ro",
                isa => "Str",
                required =>1,
        );


        sub init{
            my $self = shift;
            my $dancerPort = &getPort;
            my $myName = $self->name;
            
            set port => $dancerPort;
            debug "Dancer service $myName port will be $dancerPort";

            share($self->{units});  #hash
            my %emptyHash : shared = ();
            $self->{units} = \%emptyHash;
            
            $self->initAvahi;
            debug("avahi initialized");
            $self->initTrackingEngine;
            debug("tracking engine is rolling");
            $self->initPaths;
            debug("paths initialized");
            return 1;
        }
        
        sub initPaths{
            my $self = shift;
            my $myName = $self->name;
            
            #returns info about requested service
            get "/zeroconf/".$myName."/service/:sName" => sub {
                {
                        lock($self->{units});
                        my $requestedType = param('sName');
                        return $self->{units}{$requestedType};
                }
                            
            };
            
            #returns all available services
            get "/zeroconf/".$myName."/service" => sub {
                {
                        lock($self->{units});
                        return $self->{units};                        
                }                            
            };
            
            
            get "/zeroconf/".$myName."/ping" => sub {
                return "pong";                            
            };

            return 1;
        }
        
        sub initTrackingEngine{
                my $self = shift;
		my @Params = ($self);

		my $thr = threads->create(\&trackAvahiUnits, @Params);
		$thr->detach();
                
                debug("trackingEngine started");
                return 1;                
        }
        
        

        sub trackAvahiUnits{
                my @InboundParams = @_;
		my $self = $InboundParams[0];
                
                while (1) {
                        my $stuffToTrack =  config->{unitIdentifiers};
                        {                                
                                lock($self->{units});                                
                                %{$self->{units}}=();   #indepen
                                
                                while (my($unitType, $unitCode) = each %$stuffToTrack){                                       
                                       my $res =  $self->findAvahiUnits($unitCode);
                                       my $resSize = keys %$res;
                                       if ($resSize > 0) {
                                                $self->{units}{$unitType} = $res ;                                                
                                       }
                                }
                                #say($self->{units}{master}{Master1}{address});
                        }                        
                        
                        sleep(config->{trackingInterval})
                }                
                return 1;
        }




        
        sub initAvahi{
		use Net::Rendezvous::Publish;
		my $publisher = Net::Rendezvous::Publish->new
			or die "couldn't make a Publisher object";
                
                my $avahiName = config->{myName};
                my $serviceType = config->{unitIdentifiers}{avahi};
                        
		my $service = $publisher->publish(
			name => $avahiName,
			type => $serviceType,
			port => config->{port},
		);
		return 1;
	}
        
        
        sub findAvahiUnits{
		my $self = shift;
		my $serviceTypeToFind = shift;

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
				%row = (address => $sensorAddress, port => $sensorPort, lastSeen=>time);
				$sensorsLoc{$sensorName}= \%row;
				$sensorName = $sensorAddress = $sensorPort =0;
			}
		}

		return \%sensorsLoc;
	}
        
        
        sub getPort {
            my $proto = getprotobyname("tcp");
            my $iaddr   = inet_aton("localhost");
            my $paddr = sockaddr_in(0, $iaddr);
            socket(SOCK, PF_INET, SOCK_STREAM, $proto);
            connect(SOCK, $paddr);
            my $port = (sockaddr_in(getsockname(SOCK)))[0];
            close(SOCK);
            return $port;
        }

        1;
}
