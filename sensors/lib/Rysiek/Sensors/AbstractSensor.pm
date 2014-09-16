package Rysiek::Sensors::AbstractSensor 0.1{
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

  has "sensorConfig" =>(
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
    print Dumper( $self->{sensorConfig});
  }

  sub init{
    my $self = shift;
    debug ("Init started for sensor ". ref $self);

    share($self->{registeredMasters});
    my %emptyHash : shared = ();
    $self->{registeredMasters} = \%emptyHash;

    $self->initAvahi;
    debug ("Avahi done for ". ref $self);
    $self->initPaths;
    debug ("Paths done for ". ref $self);
    # $self->initMastersMonitor;
    # debug ("init masters monitor done for ". ref $self);
    $self->initSensing;
    debug ("initSensing done for ". ref $self);
  }

  sub initSensing{
    my $self = shift;
    my @Params = ($self);
    my $name = $self->name;
    debug("sensor $name is entering sensingLoop");
    my $thr = threads->create(\&sensingLoop, @Params);
    $thr->detach();
  }

  sub sensingLoop{
    my @InboundParameters = @_;
    my $self = $InboundParameters[0];
    my $name = $self->name;
    debug("sensor $name is entering constantMeasurements");
    $self->constantMeasurements();
  }

  #if didn't receive "register" from a master for more than x seconds - remove it
  sub initMastersMonitor{
    my $self = shift;
    my @Params = ($self);
    my $thr = threads->create(\&checkMasters, @Params);
    $thr->detach();
  }

  sub checkMasters{
    my @InboundParameters = @_;
    my $self = $InboundParameters[0];

    while(1){
      {
        lock($self->{registeredMasters});
        my $size = keys $self->{registeredMasters};
        # debug($self->name . "has masters: " . $size);

        foreach my $master (keys $self->{registeredMasters}){
          my $lastRegisterTime = $self->{registeredMasters}{$master}{time};
          my $currTime = time;
          my $elapsed = $currTime - $lastRegisterTime;

          if($elapsed > $self->sensorConfig()->[0]->{"masterRemoveThreshold"} ){
            # debug($self->name ." will be removed!!!!!!!!!!!!");
            delete $self->{registeredMasters}{$master};
          }
        }
      }

      sleep $self->sensorConfig()->[0]->{"mastersCheckFrequency"};
    }
  }


  sub initAvahi{
    my $self = shift;
    use Net::Rendezvous::Publish;
    my $publisher = Net::Rendezvous::Publish->new
    or die "couldn't make a Publisher object";
    my $service = $publisher->publish(
    name => $self->name,
    type => '_nufw._tcp',
    port => $self->port,
    );
    1;
  }


  sub initPaths{
    my $self = shift;
    my $mName = $self->name;
    my $cfg  = $self->sensorConfig();


    #to get single measurement
    get "/sensors/".$mName ."/value" => sub {
      if($self->authorizeMaster() ){
        return  $self->getMeasurement($mName);
      }
    };

    #params: user, token
    get "/sensors/".$mName ."/subscribed" => sub {
      if($self->authorizeMaster() ){
        $self->isSubscribed;
      }
    };


    #to register master in sensor to be posted with results
    post "/sensors/".$mName."/subscribe" => sub {
      debug (params->{user}." is trying to subscribe to sensor $mName ");

      if($self->authorizeMaster() ){
        {
          lock($self->{registeredMasters});
          share($self->{registeredMasters}{params->{user}});
          my %row :shared;
          %row = (
            ip => request->remote_address,
            port => params->{port},
            time => time
          );
          $self->{registeredMasters}{params->{user}} = \%row;
        }
        debug (params->{user}." subscribed succesfully to  sensor $mName ");
        say "ok";
      }
    };

    1;
  }

  sub isSubscribed{
    my $self = shift;
    {
      lock($self->{registeredMasters});
      if(params->{user} ~~ $self->{registeredMasters} ){
        return 1;
      }else{
        return 0;
      }
    }
  }

sub authorizeMaster{
  my $self = shift;
  $self->checkCredentials("sensorKnownMasters", "mastersTokens");
}

sub checkCredentials{
  my $self = shift;
  my $usersBase = shift;
  my $passBase = shift;
  my $mName = $self->name;
  my $user = params->{user};
  my $token = params->{token};

  debug ("$user is trying to authorize in $mName with token $token. Request path:". request->path_info);

  if(defined $user && defined $token){
  if($user ~~ $self->sensorConfig->[0]->{$usersBase}){    
    if($token eq $self->sensorConfig->[0]->{$passBase}{$user}){
      debug ("$user authorized successfuly in $mName ");
      return 1;
    }
  }
}

  debug ("$user wrong credentials to  $mName. Sending 403.. ");
  send_error("Wrong credentials", 403);
  1;
}


# for a single-shot measurement
  sub getMeasurement{
    my $self = shift;
    my @res = $self->measureOnce();
    return {sensorName => $self->name, value => \@res };
  };


sub updateMastersWithValue{
  my $self = shift;
  my $val  = shift;
  my $name = $self->name;
  {
    lock($self->{registeredMasters});

    foreach my $master (keys $self->{registeredMasters}){
      my $masterIp = $self->{registeredMasters}{$master}{ip};
      my $masterPort = $self->{registeredMasters}{$master}{port};
      my $myToken = $self->sensorConfig->[0]->{"mastersCredentials"}{$master};

      my $ua = LWP::UserAgent->new;
      my $server_endpoint = "http://". $masterIp .":". $masterPort ."/masters/". $master ."/value";

      my $res = $ua->request(POST  "$server_endpoint", [sensor => ($name),
          value => $val, user => $name, token=> $myToken] );

      # Check the outcome of the response
      if (!$res->is_success) {
        my $bt = ++$self->{registeredMasters}{$master}{wrongTrials};
        warn("Unable to send values  to master $master  for time $bt!!");
        if($bt > 3){
          delete $self->{registeredMasters}{$master};
          debug("Master $master deleted from subscription.");
        }
      }else{
        $self->{registeredMasters}{$master}{wrongTrials}=0;
      }

    }
  }

}

  true;
}