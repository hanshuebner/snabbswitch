module(..., package.seeall)

-- Benchmark Solarflare send & receive

local pci           = require("lib.hardware.pci")
local ethernet      = require("lib.protocol.ethernet")
local basic_apps    = require("apps.basic.basic_apps")
local SolarFlareNic = require("apps.solarflare.solarflare").SolarFlareNic;
local freelist      = require("core.freelist")

local ffi = require("ffi")
local C = ffi.C

function get_sf_devices()
   pci.scan_devices()

   local sf_devices = {}
   for _, device in pairs(pci.devices) do
      if device.usable and device.driver == 'apps.solarflare.solarflare' then
         sf_devices[#sf_devices + 1] = device
      end
   end

   return sf_devices
end

Source = setmetatable({zone = "Source"}, {__index = basic_apps.Basic});

function Source:new(size)
   return setmetatable({}, {__index=Source})
end

function Source:pull()
   for _, o in ipairs(self.outputi) do
      for i = 1, link.nwritable(o) do
         local p = packet.allocate()
         ffi.copy(p.data, self.to_mac_address, 6)
         ffi.copy(p.data + 6, self.from_mac_address, 6)
         p.length = self.size
         link.transmit(o, p)
      end
   end
end

function Source:set_packet_addresses(from_mac_address, to_mac_address)
   self.from_mac_address, self.to_mac_address = from_mac_address, to_mac_address
   print(string.format("Sending from %02x:%02x:%02x:%02x:%02x:%02x to %02x:%02x:%02x:%02x:%02x:%02x",
                       self.from_mac_address[0],
                       self.from_mac_address[1],
                       self.from_mac_address[2],
                       self.from_mac_address[3],
                       self.from_mac_address[4],
                       self.from_mac_address[5],
                       self.to_mac_address[0],
                       self.to_mac_address[1],
                       self.to_mac_address[2],
                       self.to_mac_address[3],
                       self.to_mac_address[4],
                       self.to_mac_address[5]))
end

function Source:set_packet_size(size)
   self.size = size
end

function run (args)

   if #args < 2 then
      print(require("program.solarflare.README_inc"))
      os.exit(1)
   end

   local npackets = table.remove(args, 1)
   local packet_size = table.remove(args, 1)

   npackets = tonumber(npackets) or error("Invalid number of packets: " .. npackets)
   packet_size = tonumber(packet_size) or error("Invalid packet size: " .. packet_size)

   local sf_devices = get_sf_devices()
   if #sf_devices < 2 then
      print([[did not find two Solarflare NICs in system, can't continue]])
      main.exit(1)
   end

   local send_device = sf_devices[1]
   local receive_device = sf_devices[2]
   
   print(string.format("Sending through %s (%s), receiving through %s (%s)",
                       send_device.interface, send_device.pciaddress,
                       receive_device.interface, receive_device.pciaddress))

   local c = config.new()

   -- Topology:
   -- Source -> Solarflare NIC#1 => Solarflare NIC#2 -> Sink

   config.app(c, "source", Source)
   config.app(c, send_device.interface, SolarFlareNic, {ifname=send_device.interface, mac_address = ethernet:pton("02:00:00:00:00:01")})
   config.app(c, receive_device.interface, SolarFlareNic, {ifname=receive_device.interface, mac_address = ethernet:pton("02:00:00:00:00:02")})
   config.app(c, "sink", basic_apps.Sink)

   config.link(c, "source.tx -> " .. send_device.interface .. ".rx")
   config.link(c, receive_device.interface .. ".tx -> sink.rx")

   engine.configure(c)

   engine.app_table.source:set_packet_addresses(engine.app_table[send_device.interface].mac_address,
                                                engine.app_table[receive_device.interface].mac_address)
   engine.app_table.source:set_packet_size(packet_size)

   engine.Hz = false
   
   local start = C.get_monotonic_time()
   timer.activate(timer.new("null", function () end, 1e6, 'repeating'))
   while engine.app_table.source.output.tx.stats.txpackets < npackets do
      engine.main({duration = 0.01, no_report = true})
   end
   local finish = C.get_monotonic_time()
   local runtime = finish - start
   local packets = engine.app_table.source.output.tx.stats.txpackets
   engine.report()
   engine.app_table[send_device.interface]:report()
   engine.app_table[receive_device.interface]:report()
   print()
   print(("Processed %.1f million packets in %.2f seconds (rate: %.1f Mpps, %.2f Gbit/s)."):format(packets / 1e6,
                                                                                                   runtime, packets / runtime / 1e6,
                                                                                                   ((packets * packet_size * 8) / runtime) / (1024*1024*1024)))
end
