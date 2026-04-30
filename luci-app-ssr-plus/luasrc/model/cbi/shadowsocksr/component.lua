local m, s

m = SimpleForm(
	"component_update",
	translate("Component Update"),
	translate("Check installed component versions and upgrade them online from the upstream release page.")
)
m.reset = false
m.submit = false

s = m:section(SimpleSection)
s.template = "shadowsocksr/component"

return m