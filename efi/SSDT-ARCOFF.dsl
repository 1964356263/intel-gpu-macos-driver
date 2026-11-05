/*
 * Hide the Intel Arc B580 (8086:E20B) from macOS. It has no macOS driver; IONDRVFramebuffer attached
 * to it and its IOFBController kept async work pending forever, so IOGraphics never told
 * WindowServer about system sleep (CoreRC deferred the sleep ack, IOGraphics waited 90 s).
 * The card sits behind its own PCIe switch: PEG1 -> PEGP (upstream port, 1:0.0) -> downstream port
 * 2:1.0 -> GPU 3:0.0. Only PEGP is in the DSDT, so the downstream port and the GPU are declared here.
 * A "#display" name and an all-ones class code keep every framebuffer driver off the GPU;
 * OpenCore DeviceProperties cannot do this (IOPCIFamily rewrites class-code from config space).
 * Windows does not see this table's effect (Darwin only).
 */
DefinitionBlock ("", "SSDT", 2, "WEX", "ARCOFF", 0x00001000)
{
    External (_SB_.PC00.PEG1.PEGP, DeviceObj)

    If ((CondRefOf (\_OSI, Local0) && _OSI ("Darwin")))
    {
        Scope (\_SB.PC00.PEG1.PEGP)
        {
            Device (BRG1)
            {
                Name (_ADR, 0x00010000)  // _ADR: Address
                Device (GFX0)
                {
                    Name (_ADR, Zero)  // _ADR: Address
                    Method (_DSM, 4, NotSerialized)  // _DSM: Device-Specific Method
                    {
                        If ((Arg2 == Zero))
                        {
                            Return (Buffer (One)
                            {
                                 0x03
                            })
                        }

                        Return (Package (0x06)
                        {
                            "name",
                            Buffer (0x09)
                            {
                                "#display"
                            },

                            "IOName",
                            "#display",
                            "class-code",
                            Buffer (0x04)
                            {
                                 0xFF, 0xFF, 0xFF, 0xFF
                            }
                        })
                    }
                }
            }
        }
    }
}
