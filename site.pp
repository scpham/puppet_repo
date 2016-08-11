## site.pp ##

# This file (/etc/puppetlabs/puppet/manifests/site.pp) is the main entry point
# used when an agent connects to a master and asks for an updated configuration.
#
# Global objects like filebuckets and resource defaults should go in this file,
# as should the default node definition. (The default node can be omitted
# if you use the console and don't define any other nodes in site.pp. See
# http://docs.puppetlabs.com/guides/language_guide.html#nodes for more on
# node definitions.)

## Active Configurations ##

# PRIMARY FILEBUCKET
# This configures puppet agent and puppet inspect to back up file contents when
# they run. The Puppet Enterprise console needs this to display file contents
# and differences.

# Define filebucket 'main':
filebucket { 'main':
  server => 'pe-master.cisco.com',
  path   => false,
}

# Make filebucket 'main' the default backup location for all File resources:
File { backup => 'main' }


# TODO: Most of this can be yanked for PE 3.0
# TODO: Need to break these out into different types of components.
# TODO: Need to create Top Scope Class
node default {
  # tenant should be called first, or location call will fail.
  # Any variables in hiera.yaml that are resolved from a config file, needs to be looked up in this section.
  $tenant = downcase(hiera('tenant',undef))
  $provision_start_time = inline_template('<%= Time.now.localtime %>')

  # TODO: Figure out odd behaviour of top scope call with getvar str2bool
  $master = str2bool($fact_is_puppetmaster)
  if $master == true {
    $location = downcase(hiera('location','undefined'))
  }
  else{
    $citeis_location = getvar('citeis_location')
    if $citeis_location {
      $location = $citeis_location
    }
    else{
      $location = hiera('location',generate('/apps/pe-puppet/tools/bin/get_location.rb'))
    }
  }
  # We do this to set the stage of the hosts svl vs. prod. By setting a $host_env we can leverage it hiera to consolidate the data
  if $location == 'svl' {
    $host_env = 'svl'
  }
  else{
    $host_env = hiera('env',$tenant)
  }
  $role     = hiera('role','client')

  # End Variable Lookups
  $context = '/files/etc/puppetlabs/puppet/puppet.conf'
  # Checking to see if $tenant is nil,
  # TODO: Need to work with Solaris,Windows
  if $tenant == undef {
    fail("Tenant is not defined for ${host}. This host is not authorized..")
  }
  elsif $tenant != $environment {
    warning("Agent requested '${environment}' environment but is assigned to '${tenant}' environment")
    notify { "Agent requested '${environment}' environment but is assigned to '${tenant}' environment":
      loglevel => 'warning',
    }
    # TODO: Need to verify Puppet resource, and work for other OS'es
    # Create puppet agent boot strap, this is needed since the code doesn't relaunch the agent reliably
    $agent_kick = '/opt/puppet/bin/puppet agent -t --debug >/var/log/puppet-bootstrap.log 2>&1'
    file { '/tmp/puppet-bootstrap':
      replace  => "yes",
      ensure   => 'present',
      content  => "(/usr/bin/pkill puppet && rm -f /var/run/pe-puppet/agent.pid ; ${agent_kick}; ${agent_kick}; /usr/bin/nohup puppet agent &)&",
      mode     => 755,
      before   => Exec['rerun puppet'],
    }
    augeas { 'puppet.conf [agent] environment':
      context => $context,
      changes => "set $context/agent/environment '${tenant}'",
      #onlyif => "match ${context}/agent/environment size == 0",
      before => Exec['rerun puppet']
    }
    # This is a hack to fork into the background, kill the current puppet, and
    # start a new puppet run with the new environment. The 'true' is an
    # additional hack to pass Puppet's argument validator.
    exec { 'rerun puppet':
      command   => ' true ; /usr/bin/at now + 3 minutes -f /tmp/puppet-bootstrap', # Need to make sure there's a space in front of the true call
      path      => ['/bin','/sbin','/usr/bin','/opt/puppet/bin'],
      provider  => 'shell',
      logoutput => 'true',
    }
  }
  else {
    $agent_kick = '/opt/puppet/bin/puppet agent -t --debug >/var/log/puppet-bootstrap.log 2>&1'
    $pe_master = hiera('csco_puppet::agent::master','pe-master.cisco.com')

    augeas { 'Change Master Host In Agent':
      context => $context,
      changes => ["set ${context}/agent/server '${pe_master}'"],
      onlyif  => "match agent/server[.='${pe_master}'] size == 0",
      #notify  => Exec['rerun puppet master change']
    }
    file { '/tmp/puppet-bootstrap':
      replace  => "yes",
      ensure   => 'present',
      content  => "(/usr/bin/pkill puppet && rm -f /var/run/pe-puppet/agent.pid ; ${agent_kick}; ${agent_kick}; /usr/bin/nohup puppet agent &)&",
      mode     => 755,
      before   => Augeas['Change Master Host In Agent'],
    }

    exec { 'rerun puppet master change':
      command   => ' true ; /usr/bin/at now + 5 minutes -f /tmp/puppet-bootstrap; /usr/bin/at now + 10 minutes -f /tmp/puppet-bootstrap', # Need to make sure there's a space in front of the true call
      path      => ['/bin','/sbin','/usr/bin','/opt/puppet/bin'],
      provider  => 'shell',
      logoutput => 'true',
      subscribe => Augeas['Change Master Host In Agent'],
      refreshonly => true, #Augeas['Change Master Host In Agent']
    }


    # Setting Top Scope
    $host_purpose = hiera('purpose','none')
    $is_master = $::fact_is_puppetmaster
    #$activemq_brokers = hiera('csco_mcollective::activemq_brokers')
    # Lookup classes variable found in the hieradata/hosts location
    hiera_include('classes')
  }
}
# vim: set ts=2 sw=2 et :
# encoding: utf-8
