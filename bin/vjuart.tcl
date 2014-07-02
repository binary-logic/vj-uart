#!/usr/local/altera/quartus/bin/quartus_stp -t

#   vjuart.tcl - Virtual JTAG UART proxy for Altera devices
#
#   Description: Create a TCP connection to listen for a telnet connection
#   and relay the telnet stream through the Altera VJTAG connection to a
#   I/O FIFO buffer.  This TCL script requires Quartus STP to be installed.
#   Provides a simple interface to the Terasic DE0-Nano
#  
#   Copyright (C) 2014  Binary Logic (nhi.phan.logic at gmail.com).
#
#   This file is part of the Virtual JTAG UART toolkit
#   
#   Virtual UART is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#   
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#   
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

###################### Parameters ###########################

set service_port 2323
set listen_address 127.0.0.1

###################### Code #################################

# Setup connection
proc setup_blaster {} {
	global usbblaster_name
	global test_device

	foreach hardware_name [get_hardware_names] {
		if { [string match "USB-Blaster*" $hardware_name] } {
			set usbblaster_name $hardware_name
		}
	}

	puts "Select JTAG chain connected to $usbblaster_name.";

	# List all devices on the chain, and select the first device on the chain.
	#Devices on the JTAG chain:


	foreach device_name [get_device_names -hardware_name $usbblaster_name] {
		if { [string match "@1*" $device_name] } {
			set test_device $device_name
		}
	}
	puts "Selected device: $test_device.";
}

# Open device 
proc openport {} {
	global usbblaster_name
        global test_device
	open_device -hardware_name $usbblaster_name -device_name $test_device
	device_lock -timeout 10000
}


# Close device.  Just used if communication error occurs
proc closeport { } {
	global usbblaster_name
	global test_device

	# Set IR back to 0, which is bypass mode
	device_virtual_ir_shift -instance_index 0 -ir_value 3 -no_captured_ir_value

	catch {device_unlock}
	catch {close_device}
}

# Convert decimal number to the required binary code
proc dec2bin {i {width {}}} {

    set res {}
    if {$i<0} {
        set sign -
        set i [expr {abs($i)}]
    } else {
        set sign {}
    }
    while {$i>0} {
        set res [expr {$i%2}]$res
        set i [expr {$i/2}]
    }
    if {$res == {}} {set res 0}

    if {$width != {}} {
        append d [string repeat 0 $width] $res
        set res [string range $d [string length $res] end]
    }
    return $sign$res
}

# Convert a binary string to a decimal/ascii number
proc bin2dec {bin} {
    if {$bin == 0} {
        return 0
    } elseif {[string match -* $bin]} {
        set sign -
        set bin [string range $bin[set bin {}] 1 end]
    } else {
        set sign {}
    }
    return $sign[expr 0b$bin]
}

# Send data to the Altera input FIFO buffer
proc send {chr} {
	device_virtual_ir_shift -instance_index 0 -ir_value 1 -no_captured_ir_value
	device_virtual_dr_shift -dr_value [dec2bin $chr 8] -instance_index 0  -length 8 -no_captured_dr_value
}

# Read data in from the Altera output FIFO buffer
proc recv {} {
	# Check if there is anything to read
	device_virtual_ir_shift -instance_index 0 -ir_value 2 -no_captured_ir_value
	set tdi [device_virtual_dr_shift -dr_value 0000 -instance_index 0 -length 4]
	if {![expr $tdi & 1]} {
		device_virtual_ir_shift -instance_index 0 -ir_value 0 -no_captured_ir_value
		set tdi [device_virtual_dr_shift -dr_value 00000000 -instance_index 0 -length 8]
		return [bin2dec $tdi]
	} else {
		return -1
	}
}

########## Process a connection on the port ###########################
proc conn {channel_name client_address client_port} {
	global service_port
	global listen_address
	global wait_connection

	# Connect the USB Blaster
	openport

	# Configure the channel for binary
	fconfigure $channel_name -translation binary -buffering none -blocking false

	puts "Connection from $client_address"
	# Do the "telnet mode character", command is:
	# IAC WONT LINEMODE IAC WILL ECHO
	puts -nonewline $channel_name "\377\375\042\377\373\001"
	puts $channel_name "JTAG VComm on $client_address:$service_port\r"
	puts "Stream byte counters:"
	flush $channel_name

	# Wait for telnet client to return 'junk'
	# Read and discard the junk
	after 100
	read $channel_name 4096

	variable cnt_in 0
	variable cnt_out 0

	while {1} {
		# Try to read a character from the buffer
		set onechar [read $channel_name 1]
		set numchars [string length $onechar]

		# Check for EOF first
		if {[eof $channel_name]} break

		# Did we receive something?
		if { $numchars > 0 } {
			# Convert the character to ascii code
			scan $onechar %c ascii

			#Transmit this recieved character
			send $ascii

			# Update the counters
			incr cnt_in
			puts -nonewline "\rin: $cnt_in, out: $cnt_out"
			flush stdout
		}

		# Now check data coming out from VComm
		if {[eof $channel_name]} break
		set rx [recv]
		if {$rx >= 0} {
			puts -nonewline $channel_name [format %c $rx]
			incr cnt_out
			puts -nonewline "\rin: $cnt_in, out: $cnt_out"
		}
	}
	close $channel_name
	puts "\nClosed connection"

	closeport

	set wait_connection 1
}

####################### Main code ###################################
global usbblaster_name
global test_device
global wait_connection

# Find the USB Blaster
setup_blaster

# Start the server socket
socket -server conn -myaddr $listen_address $service_port

# Loop forever
while {1} {

	# Set the exit variable to 0
	set wait_connection 0

	# Display welcome message
	puts "JTAG VComm listening on $listen_address:$service_port"

	# Wait for the connection to exit
	vwait wait_connection 
}
##################### End Code ########################################
