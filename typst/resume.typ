#let r = yaml("/data/resume.yaml")

#r.name — #r.title \
#r.email · #r.location · #r.website \
summary chars: #r.summary.len() \
links: #r.links.len(), expertise: #r.expertise.len(), jobs: #r.experience.len() \
#for job in r.experience [
  - #job.role (#job.start – #job.end), bullets: #job.at("bullets", default: ()).len(), engagements: #job.at("engagements", default: ()).len() \
  #for eng in job.at("engagements", default: ()) [
    - #eng.role at #eng.company, #eng.location (#eng.when), bullets: #eng.bullets.len() \
  ]
]
