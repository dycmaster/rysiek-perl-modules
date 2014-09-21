package Rysiek::Master 0.01 {
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
  use Time::HiRes qw/ time sleep /;

  our $zeroconfServiceLink = "";
  my $getQ  = Thread::Queue->new();
  my $postQ = Thread::Queue->new();

  has "name" => (
    is       => "ro",
    isa      => "Str",
    required => 1,
  );

  sub init {
    my $self       = shift;
    my $dancerPort = &getPort;
    set port => $dancerPort;
    debug "Dancer port will be $dancerPort";

    share( $self->{subscribedSensors} );    #hash
    my %emptyHash2 : shared = ();
    $self->{subscribedSensors} = \%emptyHash2;

    share( $self->{logicServices} );
    my %emptyHash3 : shared = ();
    $self->{logicServices} = \%emptyHash3;

    share( $self->{sensorState} );
    my %emptyHash4 : shared = ();
    $self->{sensorState} = \%emptyHash4;

    $self->initPaths;
    $self->initAvahi;
    $self->initWorkerThread;

    my $name = $self->name;
    debug("Master $name initiaded ok.");
  }

  sub initWorkerThread {
    my $self = shift;
    say "creating worker";

    my $worker = threads->create(
      sub {
        $| = 1;
        sleep 5;
        my ( $lastWorkerStart, $lastSensorTrackTime, $lastLogicTrackTime ) = ( time, time, 0 );
        my $sensorsUpdateF   = config->{sensorsUpdateFrequency};
        my $logicServUpdateF = config->{logicServicesSearchingFrequency};

        while (1) {
          $lastWorkerStart = time;

          $self->handlePostFromQueue;
          $self->handleGetFromQueue;

          if ( time - $lastSensorTrackTime >= $sensorsUpdateF ) {
            $self->findAndTrackSensorsViaZeroconfService;
            $lastSensorTrackTime = time;
          }

          if ( time - $lastLogicTrackTime >= $logicServUpdateF ) {
            $self->findAndStoreLogicServicesViaZeroconfService;
            $lastLogicTrackTime = time;
          }

          #sleep to not work too much
          my $elasped = ( time - $lastWorkerStart ) * 1000;

          #say "elasped is $elasped ms";
          my $workerPeriod = config->{workerPeriod};
          if ( $elasped < $workerPeriod ) {
            my $timeToSleep = ( $workerPeriod - $elasped ) / 1000;

            #            say "time to sleep is: $timeToSleep s";
            sleep($timeToSleep);
          }
        }
      }
    );
    say "detaching worker";
    $worker->detach();
    return 1;
  }

  sub handlePostFromQueue {
    while ( $postQ->pending() > 0 ) {
      my $item = $postQ->dequeue();
      say "Handling POST request $item";
      my $ua  = LWP::UserAgent->new;
      my $res = $ua->request( POST "$item" );
      if ( $res->is_success ) {
        say "POST request $item sent successfully";
      }
      else {
        say "unable to send POST request $item";
      }
    }
    return 1;
  }

  sub handleGetFromQueue {
    while ( $getQ->pending() > 0 ) {
      my $item = $getQ->dequeue();
      say "Handling GET request $item";
      my $res = LWP::Simple::get($item);
      if ( defined $res ) {
        say "GET request $item sent successfully";
      }
      else {
        say "unable to send GET request $item";
      }
    }
    return 1;
  }

  sub findAndTrackSensorsViaZeroconfService {
    my $self = shift;

    my $zeroconfServiceLink = $self->getBasicAvahiServiceLink;
    $zeroconfServiceLink = $zeroconfServiceLink . "service/sensor";
    my $zeroconfRes = LWP::Simple::get($zeroconfServiceLink);

    {
      lock( $self->{subscribedSensors} );
      %{ $self->{subscribedSensors} } = ();

      if ( defined $zeroconfRes ) {
        my $trackedSensors = $self->checkWhatITrack;
        my $sensorsYaml    = YAML::Tiny->read_string($zeroconfRes);

        if ( defined $sensorsYaml->[0] ) {
          foreach my $trackedSensor (@$trackedSensors) {
            next unless defined $sensorsYaml->[0]->{$trackedSensor};

            my $address = $sensorsYaml->[0]->{$trackedSensor}{address};
            my $port    = $sensorsYaml->[0]->{$trackedSensor}{port};
            if ( defined $address && defined $port ) {
              my $userName  = config->{masterName};
              my $userToken = config->{masterToken};
              my $yesNoLink =
"http://$address:$port/sensors/$trackedSensor/subscribed?user=$userName&token=$userToken";

              my $alreadySubs = LWP::Simple::get($yesNoLink);

              if ( defined $alreadySubs && $alreadySubs ne "1" ) {
                say "not subscribed yet to $trackedSensor";
                my $myPort       = config->{port};
                my $ua           = LWP::UserAgent->new;
                my $subscribeUrl = "http://$address:$port/sensors/$trackedSensor/subscribe";
                my $res          = $ua->request(
                  POST "$subscribeUrl",
                  [
                    user  => $userName,
                    token => $userToken,
                    port  => $myPort
                  ]
                );

                if ( defined $res && $res->is_success() ) {
                  say "subscribed ok to $trackedSensor";
                  my %emptyHash2 : shared = ();
                  $self->{subscribedSensors}{$trackedSensor}          = \%emptyHash2;
                  $self->{subscribedSensors}{$trackedSensor}{port}    = $port;
                  $self->{subscribedSensors}{$trackedSensor}{address} = $address;
                }
                elsif ( defined $res ) {
                  say "unable to subscribe to $trackedSensor";
                }
                else {
                  say "$trackedSensor is visible in the zeroconf service but is not reachable!";
                }
              }
              elsif ( defined $alreadySubs && $alreadySubs eq "1" ) {
                my %emptyHash2 : shared = ();
                $self->{subscribedSensors}{$trackedSensor}          = \%emptyHash2;
                $self->{subscribedSensors}{$trackedSensor}{port}    = $port;
                $self->{subscribedSensors}{$trackedSensor}{address} = $address;
              }
              else {
                say "$trackedSensor is visible in the zeroconf service but is not reachable!";
              }
            }
          }

        }
      }
      else {
        say "No reply from zeroconfService, even though it looks available";
      }
    }
  }

  sub findAndStoreLogicServicesViaZeroconfService {
    my $self = shift;

    my $zeroconfLink = $self->getBasicAvahiServiceLink;
    $zeroconfLink = $zeroconfLink . "service/processor";
    my $res = LWP::Simple::get($zeroconfLink);

    {
      lock( $self->{logicServices} );
      %{ $self->{logicServices} } = ();

      if ( defined $res ) {

        #get the list of my processors
        my $myProcessors = $self->checkMyProcessors;
        my $yaml         = YAML::Tiny->read_string($res);
        if ( defined $yaml->[0] ) {

          foreach my $availableProc ( keys $yaml->[0] ) {
            next unless $availableProc ~~ $myProcessors;

            my $address = $yaml->[0]->{$availableProc}{address};
            my $port    = $yaml->[0]->{$availableProc}{port};
            if ( defined $address && defined $port ) {

              my $user  = config->{masterName};
              my $token = config->{logicServicesTokens}{$availableProc};
              my $yesNo =
                  "http://"
                . $address . ":"
                . $port
                . "/processors/"
                . $availableProc
                . "/subscribed?user="
                . $user
                . "&token=$token";

              my $alreadySubscribed = LWP::Simple::get($yesNo);
              if ( defined $alreadySubscribed
                && $alreadySubscribed ne "true" )
              {
                say "not subscribed yet to logic processor: $availableProc";
                my $myPort = config->{port};

                my $subscribe =
                    "http://"
                  . $address . ":"
                  . $port
                  . "/processors/"
                  . $availableProc
                  . "/subscribe?user="
                  . $user
                  . "&token=$token&port=$myPort";

                my $subs = LWP::Simple::get($subscribe);
                if ( defined $subs && $subs eq "true" ) {
                  say "subscribed ok to $availableProc";
                  my %emptyHash3 : shared = ();
                  $self->{logicServices}{$availableProc}          = \%emptyHash3;
                  $self->{logicServices}{$availableProc}{address} = $address;
                  $self->{logicServices}{$availableProc}{port}    = $port;

                  #now send him current state of the sensors
                  {
                    lock( $self->{sensorState} );
                    say "updating $availableProc with current state of all sensors";
                    foreach my $sensorName ( keys %{ $self->{sensorState} } ) {
                      my $senVal = $self->{sensorState}{$sensorName};
                      my $sValUrl =
                          "http://$address:$port/processors/$availableProc/"
                        . $sensorName . "/"
                        . $senVal
                        . "?user="
                        . config->{masterName}
                        . "&token="
                        . config->{logicServicesTokens}->{$availableProc};

                      say("url is $sValUrl");
                      debug("Queueing a POST request to  $availableProc using url: $sValUrl");
                      $postQ->enqueue($sValUrl);
                    }
                  }
                }
                elsif ( defined $subs && $subs eq "false" ) {
                  say "unable to subscribe to $availableProc";
                }
                else {
                  say "$availableProc is visible in the zeroconf service but is not reachable!";
                }
              }
              elsif ( defined $alreadySubscribed ) {
                my %emptyHash3 : shared = ();
                $self->{logicServices}{$availableProc}          = \%emptyHash3;
                $self->{logicServices}{$availableProc}{address} = $address;
                $self->{logicServices}{$availableProc}{port}    = $port;
              }
              else {
                say "$availableProc is visible in the zeroconf service but is not reachable!";
              }
            }
          }
        }
      }
      else {
        say "No response from the zeroconf service!";
      }
    }
  }

  sub initPaths {
    my $self  = shift;
    my $mName = $self->name;

    #for sensors to collect measurements
    #sensor calls this to pass a value
    post "/masters/" . $mName . "/value" => sub {
      $| = 1;
      if ( $self->authorizeSensor ) {
        debug("##########################################################################");
        debug( "Collected value from sensor: " . params->{sensor} . ", value=" . params->{value} );

        {
          lock( $self->{sensorState} );
          $self->{sensorState}{ params->{sensor} } = params->{value};
        }

        {
          lock( $self->{logicServices} );
          my $servicesToNotify = keys %{$self->{logicServices}};
          debug("Logic services to notify: $servicesToNotify");

          foreach my $serviceName ( keys %{ $self->{logicServices} } ) {
            my $port    = $self->{logicServices}{$serviceName}{port};
            my $address = $self->{logicServices}{$serviceName}{address};
            if ( defined $port && defined $address ) {

              my $server_endpoint =
                  "http://$address:$port/processors/$serviceName/"
                . params->{sensor} . "/"
                . params->{value}
                . "?user="
                . config->{masterName}
                . "&token="
                . config->{logicServicesTokens}->{$serviceName};

              debug("Queueing a POST request to  $serviceName using url: $server_endpoint");
              $postQ->enqueue($server_endpoint);
            }
            else {
              debug "logic service record defined but no address/port info present!";
            }
          }    #for logicServices
        }
      }
    };    #method

    #returns currently available actions
    #user, token - only processors are eligible to call this one
    get "/masters/" . $mName . "/action" => sub {
      if ( $self->authorizeActionUser ) {

        my $actions = $self->findAvahiUnits( config->{actionService} );

        foreach my $action ( keys %{$actions} ) {   #this is how to call that action via this master
          $actions->{$action}{url} = "/masters/$mName/action/$action";
        }

        return $actions;
      }

    };

    #used to execute some action through this Master
    #user, token,  params  - only processors are eligible to call this one
    get "/masters/" . $mName . "/action/*" => sub {
      if ( $self->authorizeActionUser ) {
        my ($action) = splat;
        my $actions  = $self->findAvahiUnits( config->{actionService} );
        my $currUser = params->{user};
        debug("%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%");
        debug("Handling a request from $currUser to fire an action $action");
        return $action . " not available" if ( !exists $actions->{$action} );
        debug "action $action is good to go and will be called.";

        my $actionAddress = $actions->{$action}{address};
        my $actionPort    = $actions->{$action}{port};

        my $actionToken = config->{actionsCredentials}{$action};
        my $url =
          "http://$actionAddress:$actionPort/actions/$action/do?user=$mName&token=$actionToken";

        my $addParamsUrl;
        if ( defined params->{addParams} ) {
          my $addParams = params->{addParams};
          debug( "add params are: " . $addParams );
          $addParamsUrl = uri_escape($addParams);
          debug( "add params escaped are:" . $addParamsUrl );
        }

        $url = $url . "&addParams=" . $addParamsUrl if defined $addParamsUrl;
        $getQ->enqueue($url);

        return "ok";
      }
    };

    #used by processors and sensprs
    get "/masters/" . $mName . "/ping" => sub {
      return "ok";
    };

    1;
  }

  sub authorizeActionUser {
    my $self = shift;
    $self->checkCredentials( "knownActionUsers", "actionUsersTokens" );
  }

  sub authorizeSensor {
    my $self = shift;
    $self->checkCredentials( "knownSensors", "sensorsTokens" );
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

  sub getBasicAvahiServiceLink {
    my $self = shift;

    my $pingRes = LWP::Simple::get( $zeroconfServiceLink . "ping" );
    if ( defined $pingRes && $pingRes ne "pong" ) {
      say "zeroconf service alive but doesn't reply properly!";
    }
    elsif ( !defined $pingRes ) {
      say("zeroconf service not available with link $zeroconfServiceLink . Obtaining new link..");

      #this runs a new process for a while so it's better to avoid calling it frequently
      my $avahiResolverData = $self->findAvahiUnits( config->{avahiService} );
      if ( defined $avahiResolverData && ( keys %$avahiResolverData > 0 ) ) {
        my $avName = ( sort keys %$avahiResolverData )[0];
        my $avData = $avahiResolverData->{$avName};
        my $host   = $avData->{address};
        my $port   = $avData->{port};

        my $link = "http://$host:$port/zeroconf/$avName/";
        $zeroconfServiceLink = $link;
      }
      else {
        $zeroconfServiceLink = "";
      }
    }
    return $zeroconfServiceLink;
  }

  sub getPort {
    my $proto = getprotobyname("tcp");
    my $iaddr = inet_aton("localhost");
    my $paddr = sockaddr_in( 0, $iaddr );
    socket( SOCK, PF_INET, SOCK_STREAM, $proto );
    connect( SOCK, $paddr );
    my $port = ( sockaddr_in( getsockname(SOCK) ) )[0];
    close(SOCK);
    $port;
  }

  sub initAvahi {
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

  sub findAvahiUnits {
    my $self              = shift;
    my $serviceTypeToFind = $_[0];

    #say "service type to find is: $serviceTypeToFind";

    my @value = qx(avahi-browse -cr $serviceTypeToFind);

    my ( $inSensor, $hasName, $hasAddress, $hasPort );
    my ( $sensorName, $sensorAddress, $sensorPort );

    my %sensorsLoc : shared;

    foreach (@value) {

      if ( !$inSensor ) {
        $inSensor = 1 if /^=/;
      }

      if ($inSensor) {
        if ( !$sensorName ) {
          if (/=\s+\S+\s+\S+\s+(\S+)/xi) {
            $sensorName = $1;
            next;
          }
        }

        if ($sensorName) {
          if ( !$sensorAddress ) {
            if (/\s+address\s+=\s+\[(\S+)\]/xi) {
              $sensorAddress = $1;
              next;
            }
          }
        }

        if ( $sensorName && $sensorAddress ) {
          if ( !$sensorPort ) {
            if (/\s+port\s+=\s+\[(\S+)\]/xi) {
              $sensorPort = $1;
            }
          }
        }

      }

      if ( $sensorName && $sensorAddress && $sensorPort ) {

        share( $sensorsLoc{$sensorName} );
        my %row : shared;
        %row = ( address => $sensorAddress, port => $sensorPort );
        $sensorsLoc{$sensorName} = \%row;

        $sensorName = $sensorAddress = $sensorPort = 0;
      }
    }

    return \%sensorsLoc;
  }

  sub checkWhatITrack {
    my $self = shift;
    return config->{trackedSensors};
  }

  sub checkMyProcessors {
    return config->{myLogicServices};
  }

  1;
}
