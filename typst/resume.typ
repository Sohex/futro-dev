#let r = yaml("/data/resume.yaml")

#set document(title: r.name + " — resume", author: r.name)
#set page(paper: "us-letter", margin: (x: 1.7cm, y: 1.5cm))
#set text(size: 10pt)
#set list(spacing: 0.55em)

#let section(title) = {
  v(0.6em)
  text(size: 11pt, weight: "bold", tracking: 0.04em, upper(title))
  v(-0.5em)
  line(length: 100%, stroke: 0.5pt)
  v(0.1em)
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
#columns(3, gutter: 1em)[
  #for item in r.expertise [- #item]
]

#section("Experience")
#for job in r.experience [
  #grid(
    columns: (1fr, auto),
    column-gutter: 1em,
    [*#job.role*#if job.at("company", default: "") != "" [ — #job.company]],
    [#job.start – #job.end],
  )
  #if job.at("location", default: "") != "" [#text(size: 9pt, style: "italic", job.location)]
  #if job.at("note", default: "") != "" [#emph(job.note)]
  #for b in job.at("bullets", default: ()) [- #b]
  #for e in job.at("engagements", default: ()) [
    #v(0.2em)
    #pad(left: 0.8em)[
      #grid(
        columns: (1fr, auto),
        column-gutter: 1em,
        [*#e.company* — #emph(e.role)],
        [#e.when],
      )
      #for b in e.bullets [- #b]
    ]
  ]
  #v(0.45em)
]
