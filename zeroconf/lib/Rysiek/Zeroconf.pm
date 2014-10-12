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
  use Thread::Queue;
  use Time::HiRes qw/ time sleep /;

  my $postQ = Thread::Queue->new();

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
    $self->initWorkerThread;
    debug("tacking engine is initialized");
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

  sub initWorkerThread{
    my $self = shift;
    say "creating a worker thread";
    my $worker = threads->create(
      sub{
        $|=1;
        sleep 5;
        debug "worker is rolling";
        my ( $lastWorkerStart, $lastAvahiScanTime ) = ( time, time);
        my $avahiScanF   = config->{avahiScanFrequency};
        my $workerPeriod = config->{workerPeriod};

        while (1) {
          $lastWorkerStart = time;

          $self->handlePostFromQueue;

          if ( time - $lastAvahiScanTime >= $avahiScanF ) {
            $self->trackAvahiUnits;
            $lastAvahiScanTime = time;
          }

          #sleep to not work too much
          my $elasped = ( time - $lastWorkerStart ) * 1000;

          #say "elasped is $elasped ms";
          if ( $elasped < $workerPeriod ) {
            my $timeToSleep = ( $workerPeriod - $elasped ) / 1000;
            sleep($timeToSleep);
          }
        }
      }
    );
    say"detaching worker";
    $worker->detach();
    return 1;
  }

  #find services of certain types and notify them about your service so they can
  #start using the zeroconf service
  sub trackAvahiUnits{
    $|=1;
    my $self = shift;
    my $stuffToTrack =  config->{unitTypesToTrack};
    my $stuffToOfferService = config->{serviceTypesToOfferService};

    {                                
      lock($self->{units});                                
      %{$self->{units}}=();

      foreach(@$stuffToTrack){
        my $unitCode = config->{unitIdentifiers}{$_};
        my $res =  $self->findAvahiUnits($unitCode);
        my $resSize = keys %$res;
        if ($resSize > 0) {
          $self->{units}{$_} = $res ;                                                
          if ($_ ~~ @$stuffToOfferService){
            foreach my $foundSer (keys %$res){
              my $linkBeg = config->{serviceTypeLinks}{$_};
              my $link = "http://$res->{$foundSer}{address}:$res->{$foundSer}{port}/$linkBeg/$foundSer/zeroconf";
              my $data = { user => config->{myName}, token => config->{myToken}
                  , port => config->{port} };
              my $linkAndObjects = { url => $link, data => $data };
              $postQ->enqueue($linkAndObjects);
            }
          }
        }
        #say "unit type: $_, unit code: $unitCode, units found: $resSize";
      }
    }                        
    return 1;
  }

  sub handlePostFromQueue{
    while ( $postQ->pending() > 0 ) {
      my $item = $postQ->dequeue();
      my $ua  = LWP::UserAgent->new;
      my $res = $ua->request( POST "$item->{url}", $item->{data} );
      if (! $res->is_success ) {
        say "unable to send POST request $item->{url}";
      }
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
