/* USB map (XHUB method, 5T33Z0/XHUB-Mapper) from a USBToolBox discovery on Windows (2026-10-24) on the test machine.
 * 15 of 24 endpoints: front USB-C full, front 2x USB-A, rear 10G USB-A and rear USB-C USB3-only, rear 5G hub,
 * rear USB 2.0 hub, onboard USB audio, Intel Bluetooth. Dropped: BIOS USB 2.0 port (12), AURA (4), empty hub (13). */
DefinitionBlock ("", "SSDT", 2, "OCLT", "XHUB", 0x00000000)
{
    External (_SB_.PC00.XHCI.RHUB, DeviceObj)

    // ---- \_SB_.PC00.XHCI: RHUB -> XHUB (15 active ports) ----
    Scope (\_SB_.PC00.XHCI.RHUB)
    {
        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }
            Else
            {
                Return (0x0F)
            }
        }
    }

    Device (\_SB_.PC00.XHCI.XHUB)
    {
        Name (_ADR, 0x00)
        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (0x0F)
            }
            Else
            {
                Return (Zero)
            }
        }

        Device (HS01)
        {
            Name (_ADR, 0x01)  // Front USB-C
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x09,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (HS02)
        {
            Name (_ADR, 0x02)  // ASUS USB Audio (onboard)
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0xFF,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (HS08)
        {
            Name (_ADR, 0x08)  // Front USB-A left
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x03,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (HS09)
        {
            Name (_ADR, 0x09)  // Front USB-A right
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x03,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (HS10)
        {
            Name (_ADR, 0x0A)  // ASM107x hub: rear 4x USB-A 5G
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0xFF,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (HS11)
        {
            Name (_ADR, 0x0B)  // Genesys hub: rear 3x USB 2.0
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0xFF,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (HS14)
        {
            Name (_ADR, 0x0E)  // Intel Bluetooth (BE202, 8087:0038)
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0xFF,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS01)
        {
            Name (_ADR, 0x11)  // Front USB-C
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x09,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS02)
        {
            Name (_ADR, 0x12)  // Rear USB-C 20G
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x09,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS03)
        {
            Name (_ADR, 0x13)  // Rear USB-A 10G #1
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x03,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS04)
        {
            Name (_ADR, 0x14)  // Rear USB-C 10G
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x09,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS05)
        {
            Name (_ADR, 0x15)  // Rear USB-A 10G #2
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x03,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS06)
        {
            Name (_ADR, 0x16)  // Front USB-A left
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x03,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS07)
        {
            Name (_ADR, 0x17)  // Front USB-A right
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0x03,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }

        Device (SS08)
        {
            Name (_ADR, 0x18)  // ASM107x hub: rear 4x USB-A 5G
            Method (_UPC, 0, NotSerialized)
            {
                Return (Package (0x04)
                {
                    0xFF,
                    0xFF,
                    Zero,
                    Zero
                })
            }

            Method (_PLD, 0, NotSerialized)
            {
                Return (Package (0x01)
                {
                    Buffer (0x10)
                    {
                        /* 0000 */  0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        /* 0008 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                    }
                })
            }
        }
    }
}
