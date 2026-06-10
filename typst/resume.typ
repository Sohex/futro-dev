#let r = yaml("/data/resume.yaml")

#set document(title: r.name + " — resume", author: r.name)
#set page(paper: "us-letter", margin: (x: 1.4cm, y: 1.1cm))
#set text(font: "Iosevka Custom", size: 8.5pt)
#set par(leading: 0.5em, spacing: 0.48em)
#set list(spacing: 0.3em)

#show link: underline

#let section(title) = {
  v(0.3em)
  text(size: 11pt, weight: "bold", tracking: 0.04em, upper(title))
  v(-0.5em)
  line(length: 100%, stroke: 0.5pt)
  v(0.05em)
}

#align(center)[
  #text(size: 17pt, weight: "bold", r.name) \
  #r.title \
  #text(size: 9pt)[
    #link("mailto:" + r.email, r.email)
    · #link(r.website, r.website.replace("https://", ""))
    #for l in r.links [ · #link(l.url, l.url.replace("https://", "").replace("www.", ""))]
    · #r.location
  ]
]

#section("Summary")
#r.summary

#section("Areas of Expertise")
#for g in r.expertise [
  #block(below: 0.4em)[*#g.group:* #g.items.join(", ")]
]

#if r.at("projects", default: ()) != () [
  #section("Projects")
  #for p in r.projects [
    #block(sticky: true)[
      #grid(
        columns: (1fr, auto),
        column-gutter: 1em,
        [*#p.name*],
        [#if p.at("url", default: "") != "" [#text(size: 8.5pt)[#link(p.url, p.url.replace("https://", "").replace("www.", ""))]]],
      )
    ]
    #for b in p.bullets [- #b]
    #v(0.08em)
  ]
]

#section("Experience")
#for job in r.experience [
  #block(sticky: true)[
    #grid(
      columns: (1fr, auto),
      column-gutter: 1em,
      [*#job.role*#if job.at("company", default: "") != "" [ — #job.company]],
      [#job.start – #job.end],
    )
  ]
  #if job.at("location", default: "") != "" [#text(size: 9pt, style: "italic", job.location)]
  #if job.at("note", default: "") != "" [#emph(job.note)]
  #for b in job.at("bullets", default: ()) [- #b]
  #for e in job.at("engagements", default: ()) [
    #v(0.05em)
    #pad(left: 0.8em)[
      #grid(
        columns: (1fr, auto),
        column-gutter: 1em,
        [*#e.company* — #emph(e.role)],
        [#e.when],
      )
      #if e.at("location", default: "") != "" [#text(size: 9pt, style: "italic", e.location)]
      #for b in e.bullets [- #b]
    ]
  ]
  #v(0.08em)
]
