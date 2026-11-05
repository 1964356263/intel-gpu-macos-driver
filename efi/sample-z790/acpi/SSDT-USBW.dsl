/*
 * USB wake virtual device for USBWakeFixup.kext (osy, v1.0).
 * macOS only turns a USB (keyboard/mouse) wake into a full wake when the ACPI node on the wake GPE
 * carries a top-level acpi-wake-type; OpenCore DeviceProperties only reach the PCI device. The kext
 * matches this PNP0D10 device and sets it. It shares XHCI's _PRW (GPE 0x6D); SSDT-PCHWAKE leaves
 * XHCI as the only S3 wake source on that GPE, so nothing else gains display wake.
 */
DefinitionBlock ("", "SSDT", 2, "WEX", "USBW", 0x00001000)
{
    External (_SB_.PC00.XHCI._PRW, MethodObj)    // 0 Arguments

    If ((CondRefOf (\_OSI, Local0) && _OSI ("Darwin")))
    {
        If (CondRefOf (\_SB.PC00.XHCI._PRW))
        {
            Device (\_SB.USBW)
            {
                Name (_HID, "PNP0D10")  // _HID: Hardware ID
                Name (_UID, "WAKE")  // _UID: Persistent Unique ID
                Method (_PRW, 0, NotSerialized)  // _PRW: Power Resources for Wake
                {
                    Return (\_SB.PC00.XHCI._PRW ())
                }
            }
        }
    }
}
