package Rysiek::Master 0.01{
  use 5.020;
  use Moose;
  use Socket;
  use Dancer ':syntax';
  use Data::Dumper;
  use threads;
  use threads qw(yield);
  use threads::shared;
  use HTTP::Request::Common;
  use LWP::UserAgent;
  use LWP::Simple qw(!get);
  use URI::Escape;
  use Thread::Queue;
  use YAML::Tiny;

  my $sensors :shared;
  my $subscribedSensors: shared;
  my $getQ = Thread::Queue->new();
  my $postQ = Thread::Queue->new();


  has "name" =>(
    is => "ro",
    isa => "Str",
    required =>1,
  );

  sub init{
    my $self = shift;
    my $dancerPort = &getPort;
    set port => $dancerPort;
    debug "Dancer port will be $dancerPort";

    share($self->{sensors});  #hash
    my %emptyHash : shared = ();
    $self->{sensors} = \%emptyHash;

    share($self->{subscribedSensors});  #hash
    my %emptyHash2: shared = ();
    $self->{subscribedSensors} = \%emptyHash2;

    share($self->{logicServices});
    my %emptyHash3: shared = ();
    $self->{logicServices} = \%emptyHash3;

    $self->initPaths;

    &handleGetFromQueue;
    &handlePostFromQueue;

    $self->initAvahi;
    $self->initSensorsTrackingEngine;
    $self->initLogicServicesTracking;

    my $name = $self->name;
    debug("Master $name initiaded ok.");
  }

  sub handlePostFromQueue{
    my $thr = threads->create(
      sub{
        $|=1;
        while(defined(my $item = $postQ->dequeue())){
          say"Handling POST request $item";
          my $ua = LWP::UserAgent->new;
          my $res=$ua->request(POST "$item");
          if($res->is_success){
            say"POST request $item sent successfully";
          }else{
            say"unable to send POST request $item";
          }
        }
      }
    );
    $thr->detach();
    return 1;
  }

  sub handleGetFromQueue{
    my $thr = threads->create(
      sub{
        $|=1;
        while(defined(my $item = $getQ->dequeue())){
          say"Handling GET request $item";
          my $res = LWP::Simple::get( $item);
          if(defined $res){
            say"GET request $item sent successfully";
          }else{
            say"unable to send GET request $item";
          }
        }
      }
    );
    $thr->detach();
    return 1;
  }

  sub initPaths{
    my $self = shift;
    my $mName = $self->name;


    #for sensors to collect measurements
    #sensor calls this to pass a value
    post "/masters/".$mName."/value" => sub {
      $|=1;
      if($self->authorizeSensor){
        debug("##########################################################################");
        debug("Collected value from sensor: " . params->{sensor}
        .", value=".params->{value});
        {
          lock($self->{logicServices});

          foreach my $serviceName (keys %{$self->{logicServices}}){
            my $port = $self->{logicServices}{$serviceName}{port};
            my $address = $self->{logicServices}{$serviceName}{address};
            if(defined $port && defined $address){

              my $server_endpoint="http://$address:$port/processors/logicService1/"
              .params->{sensor}."/".params->{value}."?user="
              .config->{masterName}."&token="
              .config->{logicServicesTokens}->{$serviceName};

              debug("Queueing a POST request to  $serviceName using url: $server_endpoint");
              $postQ->enqueue($server_endpoint);
            }else{
              debug"logic service record defined but no address/port info present!";
            }

          }#for logicServices
        }
      }

    };#method


    #returns currently available actions
    #user, token - only processors are eligible to call this one
    get "/masters/".$mName."/action" => sub {
      if($self->authorizeActionUser){

        my $actions = $self->findAvahiUnits(config->{actionService});

        foreach my $action(keys %{$actions}){  #this is how to call that action via this master
          $actions->{$action}{url} = "/masters/$mName/action/$action";
        }

        return $actions;
      }

    };

    #used to execute some action through this Master
    #user, token,  params  - only processors are eligible to call this one
    get "/masters/".$mName."/action/*" => sub {
      if($self->authorizeActionUser){
        my ($action) = splat;				
        my $actions = $self->findAvahiUnits(config->{actionService});
        my $currUser = params->{user};
        debug("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        debug("Handling a request from $currUser to fire an action $action");
        return $action." not available" if (! exists $actions->{$action});
        debug "action $action is good to go and will be called.";

        my $actionAddress = $actions->{$action}{address};
        my $actionPort = $actions->{$action}{port};

        my $actionToken = config->{actionsCredentials}{$action};
        my $url = "http://$actionAddress:$actionPort/actions/$action/do?user=$mName&token=$actionToken";

        my $addParamsUrl;
        if (defined params->{addParams}) {
          my $addParams = params->{addParams};
          debug("add params are: ". $addParams );
          $addParamsUrl = uri_escape($addParams);
          debug("add params escaped are:".$addParamsUrl);
        }				

        $url= $url . "&addParams=". $addParamsUrl if defined $addParamsUrl;
        $getQ->enqueue($url);

        return "ok";
      }
    };

    #used by processors and sensprs
    get "/masters/".$mName."/ping" => sub {
      return "ok";
    };

    1;
  }
  sub authorizeActionUser{
    my $self = shift;
    $self->checkCredentials("knownActionUsers", "actionUsersTokens");
  }

  sub authorizeSensor{
    my $self = shift;
    $self->checkCredentials("knownSensors", "sensorsTokens");
  }

  sub checkCredentials{
    my $self = shift;
    my $usersBase = shift;
    my $passBase = shift;
    my $mName = $self->name;
    my $user = params->{user};
    my $token = params->{token};

    #debug ("$user is trying to authorize in $mName with token $token. Request path: ". request->path_info);

    if(defined $user && defined $token){
      if($user ~~ config->{$usersBase}){
        if($token eq config->{$passBase}{$user}){
          #debug ("$user authorized successfuly in $mName ");
          return 1;
        }
      }
    }

    debug ("$user wrong credentials to  $mName. Sending 403.. ");
    send_error("Wrong credentials", 403);
    1;
  }

  sub findAvahiUnits{
    my $self = shift;
    my $serviceTypeToFind = $_[0];
    #say "service type to find is: $serviceTypeToFind";

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

  sub initSensorsTrackingEngine{
    my $self = shift;
    my @Params = ($self);

    my $thr = threads->create(\&findAndSubscribeSensors, @Params);
    $thr->detach();
    debug("subscribing started");

    my $thr2 = threads->create(\&trackSubscribedSensors, @Params);
    $thr2->detach();
    debug("tracking started");

  }


  sub trackSubscribedSensors{
    $| = 1;
    my @InboundParameters = @_;
    my $self = $InboundParameters[0];
    while(1){
      {
        lock($self->{subscribedSensors});
        foreach my $sensorName (keys %{$self->{subscribedSensors}}){
          if($self->{subscribedSensors}{$sensorName}{subscribed}==1){
            my $port = $self->{subscribedSensors}{$sensorName}{port};
            my $address = $self->{subscribedSensors}{$sensorName}{address};
            if(defined $port && defined $address){

              my $url = "http://" . $address .":". $port ."/sensors/". $sensorName. "/subscribed?user=".
              config->{masterName}."&token=".  config->{masterToken};
              my $res =  LWP::Simple::get( $url);

              if(!(defined $res && $res eq "1")){
                delete $self->{subscribedSensors}{$sensorName};
                say("$sensorName was not available and it was removed from subscribedSensors");
              }

            }
          }
        }
      }##  lock on subscribedSensors

      yield();
      sleep(config->{subscribedSensorsTrackingFrequency});
    }#while(1)
  }


  sub initLogicServicesTracking{
    my $self = shift;
    my @Params = ($self);

    my $thr = threads->create(\&findAndStoreLogicServicesViaZeroconfService, @Params);
    $thr->detach();
  }

  sub findAndStoreLogicServicesViaZeroconfService{
    my @InboundParams = @_;
    my $self = $InboundParams[0];
    $|=1;

    while(1){
      my $zeroconfLink = $self->getBasicAvahiServiceLink;
      $zeroconfLink = $zeroconfLink . "service/processor";
      my $res = LWP::Simple::get($zeroconfLink);

      {
        lock($self->{logicServices});
        %{$self->{logicServices}}=();

        if(defined $res){
          #get the list of my processors
          my $myProcessors = $self->checkMyProcessors;
          my $yaml = YAML::Tiny->read_string($res);

          foreach my $availableProc (keys $yaml->[0]){
            next unless $availableProc ~~ $myProcessors;

            my $address = $yaml->[0]->{$availableProc}{address};
            my $port = $yaml->[0]->{$availableProc}{port};
            if(defined $address && defined $port){

              my $user = config->{masterName};
              my $token = config->{logicServicesTokens}{$availableProc};
              my $yesNo = "http://".$address.":".$port.
              "/processors/".$availableProc. "/subscribed?user="
              .$user."&token=$token";

              my $alreadySubscribed = LWP::Simple::get($yesNo);
              if(defined $alreadySubscribed 
                && $alreadySubscribed ne "true"){
                say "not subscribed yet to logic processor: $availableProc";
                my $myPort= config->{port};

                my $subscribe = "http://".$address.":".$port.
                "/processors/".$availableProc. "/subscribe?user="
                .$user."&token=$token&port=$myPort";

                my $subs = LWP::Simple::get($subscribe);
                if(defined $subs && $subs eq "true"){
                  say "subscribed ok";
                  my %emptyHash3: shared = ();
                  $self->{logicServices}{$availableProc} = \%emptyHash3;
                  $self->{logicServices}{$availableProc}{address}=$address;
                  $self->{logicServices}{$availableProc}{port}=$port;
                }elsif(defined $subs && $subs eq "false"){
                  say "unable to subscribe";
                }else{
                  say "$availableProc is visible in the zeroconf service but is not reachable!";
                }
              }elsif(defined $alreadySubscribed){
                my %emptyHash3: shared = ();
                $self->{logicServices}{$availableProc} = \%emptyHash3;
                $self->{logicServices}{$availableProc}{address}=$address;
                $self->{logicServices}{$availableProc}{port}=$port;
              }else{
                say "$availableProc is visible in the zeroconf service but is not reachable!";
              }
            }
          }
        }
      }
      sleep(config->{logicServicesSearchingFrequency});
    }
  }

  sub getBasicAvahiServiceLink{
    my $self = shift;
    my $avahiResolverData = $self->findAvahiUnits(config->{avahiService});
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


  sub findAndSubscribeSensors{
    my @InboundParameters = @_;
    my $self = $InboundParameters[0];
    $| = 1;
    sleep 5;
    say "Master will now start actively looking for sensors and registering itself";

    while(1){

      {
        lock($self->{subscribedSensors});
        #scan avahi to find a list of available sensors
        {
          lock ( $self->{sensors} ) ;
          $self->{sensors} = $self->findAvahiUnits(config->{sensorService});
        }

        #check sensors I want to track TODO - change it to DB-based
        my $trackedSensors =  $self->checkWhatITrack;


        #register in every sensor
        foreach my $sensorName  ( keys %{$self->{sensors}}){
          #unless we don't track it...
          next unless $sensorName ~~ $trackedSensors;


          #create next hash level
          if(! defined $self->{subscribedSensors}{$sensorName}){
            my %emptyHash2: shared = ();
            $self->{subscribedSensors}{$sensorName} = \%emptyHash2;
          }

          #only if not subscribed yet
          if($self->{subscribedSensors}{$sensorName}{subscribed}){
            next;
          }else{
            say ("$sensorName not subscribed yet");
          }

          say("Trying to subscribe to sensor $sensorName");
          my $address = $self->{sensors}{$sensorName}{'address'};
          my $port = $self->{sensors}{$sensorName}{'port'};

          my $ua = LWP::UserAgent->new;
          my $server_endpoint = "http://". $address .":". $port ."/sensors/". $sensorName. "/subscribe";
          my $res = $ua->request(POST  "$server_endpoint", [user => config->{masterName},
              token => config->{masterToken}, port=> config->{port}] );

          # Check results
          if ($res->is_success) {
            say("Subscribed to sensor $sensorName");
            $self->{badTrials}{$sensorName} = 0;
            $self->{subscribedSensors}{$sensorName}{subscribed} = 1;
            $self->{subscribedSensors}{$sensorName}{port} = $port;
            $self->{subscribedSensors}{$sensorName}{address} = $address;
          }else{
            $self->{subscribedSensors}{$sensorName}{subscribed} = 0;
            $self->{subscribedSensors}{$sensorName}{port} = $port;
            $self->{subscribedSensors}{$sensorName}{address} = $address;
            my $bt = ++$self->{badTrials}{$sensorName};
            say("Unable to subscribe to sensor $sensorName for $bt time!!");
          }
        }

      }#   lock on subscribed sensors

      yield();
      sleep(config->{sensorsUpdateFrequency});
    }
  }

  sub getPort {
    my $proto = getprotobyname("tcp");
    my $iaddr   = inet_aton("localhost");
    my $paddr = sockaddr_in(0, $iaddr);
    socket(SOCK, PF_INET, SOCK_STREAM, $proto);
    connect(SOCK, $paddr);
    my $port = (sockaddr_in(getsockname(SOCK)))[0];
    close(SOCK);
    $port;
  }

  sub initAvahi{
    use Net::Rendezvous::Publish;
    my $publisher = Net::Rendezvous::Publish->new
      or die "couldn't make a Publisher object";
    my $service = $publisher->publish(
      name => config->{masterAvahiName},
      type => config->{masterService},
      port => config->{port},
    );
    1;
  }

  sub checkWhatITrack{
    my $self = shift;
    return config->{trackedSensors};
  }

  sub checkMyProcessors{
    return config->{myLogicServices};
  }

  1;
}
