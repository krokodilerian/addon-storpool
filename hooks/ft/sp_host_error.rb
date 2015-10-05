#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2015, StorPool (storpool.com)                                    #
#                                                                            #
# Portions copyright OpenNebula Project (OpenNebula.org), CG12 Labs          #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

##############################################################################
# Script to migrate VM-s from failed host
#   Additional flags
#           -t how many times to loop in each state
#           -p <n> avoid resubmission if host comes
#                  back after n monitoring cycles
##############################################################################

##############################################################################
# WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING!
#
# This script needs to fence the error host to prevent split brain VMs. You
# may use any fence mechanism and invoke it around L105, using host_name
#
# WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING! WARNING!
#############################################################################

ONE_LOCATION=ENV["ONE_LOCATION"]

if !ONE_LOCATION
    RUBY_LIB_LOCATION="/usr/lib/one/ruby"
    VMDIR="/var/lib/one"
    CONFIG_FILE="/var/lib/one/config"
else
    RUBY_LIB_LOCATION=ONE_LOCATION+"/lib/ruby"
    VMDIR=ONE_LOCATION+"/var"
    CONFIG_FILE=ONE_LOCATION+"/var/config"
end

$: << RUBY_LIB_LOCATION

require 'syslog'

require 'opennebula'
include OpenNebula

require 'getoptlong'

def splog(message)
    Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS) { |s| s.notice message }
end

if !(host_id=ARGV[0])
    exit -1
end

repeat = nil  # By default, don't wait for monitorization cycles"
max_count = 200

opts = GetoptLong.new(
            ['--pause',    '-p',GetoptLong::REQUIRED_ARGUMENT],
            ['--timeout',    '-t',GetoptLong::REQUIRED_ARGUMENT]
        )

begin
    opts.each do |opt, arg|
        case opt
            when '--pause'
                repeat = arg.to_i
            when '--timeout'
                max_xount = arg.to_i
        end
    end
rescue Exception => e
    exit(-1)
end

begin
    client = Client.new()
rescue Exception => e
    puts "Error: #{e}"
    exit -1
end

# Retrieve hostname
host  =  OpenNebula::Host.new_with_id(host_id, client)
rc = host.info
exit -1 if OpenNebula.is_error?(rc)
host_name = host.name

hstate = host.state
splog("BEGIN host.state:#{hstate}")

if repeat
    # Retrieve host monitor interval
    monitor_interval = nil
    File.readlines(CONFIG_FILE).each{|line|
         monitor_interval = line.split("=").last.to_i if /MONITORING_INTERVAL/=~line
    }
    hstate = host.state
    splog("#{hstate} sleep #{repeat} #{monitor_interval}")
    # Sleep through the desired number of monitor interval
    sleep (repeat * monitor_interval)

    # If the host came back, exit! avoid duplicated VMs
    exit 0 if host.state != 3
end

# Loop through all vms
vms = VirtualMachinePool.new(client)
rc = vms.info_all
if OpenNebula.is_error?(rc)
    splog("can not get host VM-s. Exit -1")
    exit -1
end

state = "STATE=3"

vm_ids_array = vms.retrieve_elements("/VM_POOL/VM[#{state}]/HISTORY_RECORDS/HISTORY[HOSTNAME=\"#{host_name}\" and last()]/../../ID")

if vm_ids_array
    vmhash = Hash.new
    vm_ids_array.each do |vm_id|
        vm=OpenNebula::VirtualMachine.new_with_id(vm_id, client)
        vm.info
        vmhash[vm_id] = Hash.new
        vmhash[vm_id]["vm_id"] = vm_id
        vmhash[vm_id]["vm"] = vm
        vmhash[vm_id]["state"] = "ACTIVE/UNKNOWN"
        vmhash[vm_id]["lcm_state"] = "UNKNOWN"
        vmhash[vm_id]["prev_action"] = "none"
        vmhash[vm_id]["count"] = 0
        splog("VM #{vm_id} adding")
    end
    # Begin game
    begin
        vmhash.each do |vm_id, vmh|
            vm = vmh["vm"]
            vm.info
            vm_state = vm.state_str
            lcm_state = vm.lcm_state_str
            state =  "#{vm_state}/#{lcm_state}"
            count = vmh["count"]
            prev_action = vmh["prev_action"]
            if state == vmhash[vm_id]["state"]
                splog("VM #{vm_id} #{prev_action} #{state} count:#{count}")
                vmhash[vm_id]["count"] = 0 if count < max_count - 1
                if state == "ACTIVE/UNKNOWN" and prev_action != "resched"
                    n_state = "ACTIVE/BOOT_FAILURE"
                    vmhash[vm_id]["state"] = n_state
                    vmhash[vm_id]["prev_action"] = "resched"
                    vm.resched
                    splog("VM #{vm_id} CALLING vm.resched and WAITFOR #{n_state}")
                elsif state == "ACTIVE/BOOT_FAILURE" and prev_action != "recover"
                    n_state = "POWEROFF/LCM_INIT"
                    vmhash[vm_id]["state"] = n_state
                    vmhash[vm_id]["prev_action"] = "recover"
                    vm.recover(1)
                    splog("VM #{vm_id} CALLING vm.recover(1) and WAITFOR #{n_state}")
                elsif state == "POWEROFF/LCM_INIT" and prev_action != "undeploy"
                    n_state = "UNDEPLOYED/LCM_INIT"
                    vmhash[vm_id]["state"] = n_state
                    vmhash[vm_id]["prev_action"] = "undeploy"
                    vm.undeploy
                    splog("VM #{vm_id} CALLING vm.undeploy")
                elsif state == "UNDEPLOYED/LCM_INIT" and prev_action != "resume"
                    n_state = "ACTIVE/RUNNINNG"
                    vmhash[vm_id]["state"] = n_state
                    vmhash[vm_id]["prev_action"] = "resume"
                    vm.resume
                    splog("VM #{vm_id} CALLING vm.resume and WAITFOR #{n_state}")
                end
            elsif state == "ACTIVE/RUNNING" and (prev_action == "resume" or prev_action == "resched")
                vmhash.delete(vm_id)
                splog("VM #{vm_id} Migrated")
                next
            elsif state == "ACTIVE/UNKNOWN" and prev_action == "resched"
                next
            end
            vmhash[vm_id]["count"] += 1
            if count > max_count
                vmhash.delete(vm_id)
                splog("VM #{vm_id} Max retries reached! Giving up")
            elsif state == "ACTIVE/PROLOG_MIGRATE_FAILURE"
                vmhash.delete(vm_id)
                splog("VM #{vm_id} CLEANUP GHOST ZDBG")
            end
        end
        sleep(1.0/1.0)
    end while vmhash.size > 0
    splog("END")
else
    splog("Nothing to do. Exit")
end