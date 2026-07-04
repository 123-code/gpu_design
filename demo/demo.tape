# Reproducible terminal-GIF of the J++ -> FPGA demo.
# Requires the board plugged in and VHS (https://github.com/charmbracelet/vhs):
#   vhs demo/demo.tape        # -> docs/demo.gif
Output docs/demo.gif
Set Shell bash
Set FontSize 20
Set Width 1100
Set Height 640
Set Padding 20

Type "cat software/demo.jpp"
Enter
Sleep 2s

Type "make run-jpp JPP=software/demo.jpp READ=2"
Enter
Sleep 5s
