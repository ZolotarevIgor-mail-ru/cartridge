describe('Edit Replica Set', () => {
  it('Edit Replica Set', () => {
    cy.visit(Cypress.config('baseUrl'));
    cy.get('li').contains('router1-do-not-use-me').closest('li').find('button').contains('Edit').click();
    cy.get('.meta-test__EditReplicasetModal input[name="alias"]')
      .type('{selectall}editedRouter')
      .should('have.value', 'editedRouter');
    cy.get('.meta-test__EditReplicasetModal input[name="roles"][value="myrole"]').uncheck({ force: true });

    cy.get('.meta-test__EditReplicasetModal input[name="roles"][value="myrole"]')
      .should('not.be.checked')
      .should('not.be.checked');

    cy.get('.meta-test__EditReplicasetModal input[name="all_rw"]')
      .uncheck({ force: true })
      .should('not.be.checked');

    cy.get('.meta-test__EditReplicasetSaveBtn').click();

    cy.get('#root').contains('editedRouter').closest('li').find('.meta-test__ReplicasetList_allRw_enabled').should('not.exist');
    cy.get('span:contains(Edit is OK. Please wait for list refresh...)').click();
  })

});
