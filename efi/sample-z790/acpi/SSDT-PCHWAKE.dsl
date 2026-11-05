/*
 * PCH wake attribution for macOS (ASUS Z790 / RPL-S, also valid on other Intel 600/700-series PCHs).
 *
 * XDCI (USB device controller, 00:14.1) and CNVW (CNVi Wi-Fi, 00:14.3) share the PME GPE 0x6D with
 * XHCI and have no _STA. When their PCI function is absent, config reads return all ones, so macOS
 * reports them as the wake source ("Wake reason: XDCI CNVW") instead of XHCI and the USB keyboard wake
 * becomes a DarkWake. Report them as absent to macOS only when the PCI function really is missing;
 * a board that has the device (e.g. a laptop with CNVi Wi-Fi) keeps it, and other OSes are untouched.
 *
 * HDAS (HD audio, 00:1F.3) is on the same GPE and is listed next to XHCI ("Wake reason: XHCI HDAS"),
 * which still yields a DarkWake. Audio is not a wake source: under macOS its _PRW (renamed to XPRW by
 * the paired OpenCore ACPI patch, Base \_SB.PC00.HDAS) reports S0-only wake. XHCI keeps its wake.
 */
DefinitionBlock ("", "SSDT", 2, "WEX", "PCHWAKE", 0x00001000)
{
    External (_SB_.PC00.XDCI, DeviceObj)
    External (_SB_.PC00.XDCI.DVID, FieldUnitObj)
    External (_SB_.PC00.CNVW, DeviceObj)
    External (_SB_.PC00.CNVW.VDID, FieldUnitObj)
    External (_SB_.PC00.HDAS, DeviceObj)
    External (_SB_.PC00.HDAS.XPRW, MethodObj)    // 0 Arguments

    If (CondRefOf (\_SB.PC00.XDCI))
    {
        Scope (\_SB.PC00.XDCI)
        {
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((_OSI ("Darwin") && (\_SB.PC00.XDCI.DVID == 0xFFFF)))
                {
                    Return (Zero)
                }

                Return (0x0F)
            }
        }
    }

    If (CondRefOf (\_SB.PC00.CNVW))
    {
        Scope (\_SB.PC00.CNVW)
        {
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((_OSI ("Darwin") && ((\_SB.PC00.CNVW.VDID & 0xFFFF) == 0xFFFF)))
                {
                    Return (Zero)
                }

                Return (0x0F)
            }
        }
    }

    If (CondRefOf (\_SB.PC00.HDAS.XPRW))
    {
        Scope (\_SB.PC00.HDAS)
        {
            Method (_PRW, 0, NotSerialized)  // _PRW: Power Resources for Wake
            {
                If (_OSI ("Darwin"))
                {
                    Return (Package (0x02)
                    {
                        0x6D,
                        Zero
                    })
                }

                Return (\_SB.PC00.HDAS.XPRW ())
            }
        }
    }
}
